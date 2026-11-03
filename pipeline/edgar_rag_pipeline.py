"""RAG ingestion pipeline for SEC EDGAR filings.

3-stage Ray Data pipeline adapted from the Red Hat AI examples
(examples/ray/data/rag/ray-data-pipeline):
  Stage 1: DoclingChunkActor   — parse HTML/MD + chunk (CPU)
  Stage 2: EmbedActor          — sentence-transformers embeddings (CPU)
  Stage 3: MilvusWriteActor    — insert vectors + metadata into Milvus

Designed to run as a RayJob on a RayCluster in RHOAI from a custom image
that contains this package. The cluster manifests select S3 input; local
execution can use a local seed directory.

S3 layout (under S3_PREFIX, default edgar-seed/):
  drive/legal/
  drive/compliance/
  factsheets/
  manifests/seed-manifest.json
"""

from __future__ import annotations

import json
import logging
import os
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

import ray

logger = logging.getLogger("edgar-rag")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")

# ---------------------------------------------------------------------------
# Configuration (environment variables, with sensible defaults for testing)
# ---------------------------------------------------------------------------

NUM_DOCLING_ACTORS = int(os.environ.get("NUM_DOCLING_ACTORS", "4"))
CPUS_PER_DOCLING_ACTOR = int(os.environ.get("CPUS_PER_DOCLING_ACTOR", "2"))
DOCLING_BATCH_SIZE = int(os.environ.get("DOCLING_BATCH_SIZE", "4"))

NUM_EMBED_ACTORS = int(os.environ.get("NUM_EMBED_ACTORS", "2"))
EMBED_BATCH_SIZE = int(os.environ.get("EMBED_BATCH_SIZE", "32"))
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "sentence-transformers/all-MiniLM-L6-v2")
EMBEDDING_DIM = int(os.environ.get("EMBEDDING_DIM", "384"))

NUM_MILVUS_ACTORS = int(os.environ.get("NUM_MILVUS_ACTORS", "2"))
MILVUS_BATCH_SIZE = int(os.environ.get("MILVUS_BATCH_SIZE", "64"))
MILVUS_HOST = os.environ.get("MILVUS_HOST", "milvus-milvus.milvus.svc.cluster.local")
MILVUS_PORT = int(os.environ.get("MILVUS_PORT", "19530"))
MILVUS_DB = os.environ.get("MILVUS_DB", "default")
COLLECTION_NAME = os.environ.get("MILVUS_COLLECTION", "edgar_filings")
MILVUS_TEXT_MAX_CHARS = int(os.environ.get("MILVUS_TEXT_MAX_CHARS", "8192"))
DROP_EXISTING_COLLECTION = os.environ.get("DROP_EXISTING_COLLECTION", "true").lower() == "true"

CHUNK_MAX_TOKENS = int(os.environ.get("CHUNK_MAX_TOKENS", "256"))

# Input: "s3" (selected by cluster manifests) or "local" (default for local testing)
INPUT_SOURCE = os.environ.get("INPUT_SOURCE", "local").lower()

# Local fallbacks
INPUT_PATH = os.environ.get("INPUT_PATH", "data/seed/drive")
MANIFEST_PATH = os.environ.get("MANIFEST_PATH", "data/seed/manifests/seed-manifest.json")
FACTSHEET_DIR = os.environ.get("FACTSHEET_DIR", "data/seed/factsheets")

# S3 seed corpus
S3_BUCKET = os.environ.get("S3_BUCKET", "")
S3_PREFIX = os.environ.get("S3_PREFIX", "edgar-seed").strip("/")
# Prefer S3_ENDPOINT; AWS_ENDPOINT_URL is also accepted for boto3 compatibility.
S3_ENDPOINT = os.environ.get("S3_ENDPOINT") or os.environ.get("AWS_ENDPOINT_URL") or ""
S3_ADDRESSING_STYLE = os.environ.get(
    "S3_ADDRESSING_STYLE", "path" if S3_ENDPOINT else "auto"
)

PROCESS_LEGAL = os.environ.get("PROCESS_LEGAL", "true").lower() == "true"
PROCESS_COMPLIANCE = os.environ.get("PROCESS_COMPLIANCE", "true").lower() == "true"
PROCESS_FACTSHEETS = os.environ.get("PROCESS_FACTSHEETS", "true").lower() == "true"


# ---------------------------------------------------------------------------
# S3 helpers
# ---------------------------------------------------------------------------

def _s3_client():
    """Build a boto3 S3 client from the environment / edgar-seed-s3 Secret."""
    import boto3
    from botocore.config import Config

    kwargs: Dict[str, Any] = {
        "config": Config(
            signature_version="s3v4",
            s3={"addressing_style": S3_ADDRESSING_STYLE},
        ),
    }
    if S3_ENDPOINT:
        kwargs["endpoint_url"] = S3_ENDPOINT
    # Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
    # AWS_DEFAULT_REGION in the environment (injected from edgar-seed-s3).
    return boto3.client("s3", **kwargs)


def _s3_join(*parts: str) -> str:
    return "/".join(p.strip("/") for p in parts if p and p.strip("/"))


def _list_s3_keys(client, bucket: str, prefix: str, suffixes: tuple) -> List[str]:
    """List object keys under prefix that end with one of suffixes."""
    keys: List[str] = []
    paginator = client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            key = obj["Key"]
            if key.endswith("/"):
                continue
            lower = key.lower()
            if any(lower.endswith(sfx) for sfx in suffixes):
                keys.append(key)
    return sorted(keys)


def _load_manifest_from_s3(client, bucket: str, prefix: str) -> dict:
    key = _s3_join(prefix, "manifests/seed-manifest.json")
    try:
        body = client.get_object(Bucket=bucket, Key=key)["Body"].read()
        manifest = json.loads(body)
    except Exception as e:
        raise RuntimeError(
            f"Could not load required S3 manifest s3://{bucket}/{key}"
        ) from e
    if not isinstance(manifest, dict):
        raise ValueError(f"S3 manifest s3://{bucket}/{key} must contain a JSON object")
    return manifest


def download_s3_object(client, bucket: str, key: str, dest_path: str) -> None:
    """Download a single S3 object to dest_path."""
    Path(dest_path).parent.mkdir(parents=True, exist_ok=True)
    client.download_file(bucket, key, dest_path)


# ---------------------------------------------------------------------------
# Input collection
# ---------------------------------------------------------------------------

def _manifest_lookup(manifest: dict) -> Dict[str, dict]:
    lookup: Dict[str, dict] = {}
    for category in ("legal", "compliance"):
        for entry in manifest.get(category, []):
            fname = entry.get("filename", "")
            if fname:
                lookup[fname] = entry
    return lookup


def collect_local_inputs(
    input_path: str,
    manifest_path: str,
    factsheet_dir: str,
) -> List[Dict[str, str]]:
    """Build filing records from a local seed directory."""
    manifest = {}
    if os.path.isfile(manifest_path):
        with open(manifest_path) as f:
            manifest = json.load(f)
    lookup = _manifest_lookup(manifest)

    records: List[Dict[str, str]] = []
    root = Path(input_path)

    for category_dir, enabled in [("legal", PROCESS_LEGAL), ("compliance", PROCESS_COMPLIANCE)]:
        if not enabled:
            continue
        cat_path = root / category_dir
        if not cat_path.is_dir():
            logger.warning("Directory not found: %s", cat_path)
            continue
        for html_file in sorted(list(cat_path.rglob("*.html")) + list(cat_path.rglob("*.htm"))):
            fname = html_file.name
            meta = lookup.get(fname, {})
            records.append({
                "source": "local",
                "path": str(html_file),
                "s3_key": "",
                "ticker": meta.get("ticker", ""),
                "cik": str(meta.get("cik", "")),
                "company": meta.get("company", ""),
                "filing_type": meta.get("filing_type", category_dir),
                "filing_date": meta.get("filing_date", ""),
                "accession": meta.get("accession", ""),
                "category": category_dir,
            })

    if PROCESS_FACTSHEETS:
        fs_dir = Path(factsheet_dir)
        if fs_dir.is_dir():
            for md_file in sorted(fs_dir.glob("*.md")):
                parts = md_file.stem.split("_")
                ticker = parts[0] if len(parts) >= 2 else ""
                cik = parts[1] if len(parts) >= 2 else ""
                records.append({
                    "source": "local",
                    "path": str(md_file),
                    "s3_key": "",
                    "ticker": ticker,
                    "cik": cik,
                    "company": "",
                    "filing_type": "factsheet",
                    "filing_date": "",
                    "accession": "",
                    "category": "factsheet",
                })

    logger.info("Collected %d local inputs from %s", len(records), input_path)
    return records


def collect_s3_inputs(bucket: str, prefix: str) -> List[Dict[str, str]]:
    """Build filing records from S3 object keys under prefix."""
    if not bucket:
        raise ValueError("S3_BUCKET is required when INPUT_SOURCE=s3")

    client = _s3_client()
    manifest = _load_manifest_from_s3(client, bucket, prefix)
    lookup = _manifest_lookup(manifest)
    records: List[Dict[str, str]] = []

    for category_dir, enabled in [("legal", PROCESS_LEGAL), ("compliance", PROCESS_COMPLIANCE)]:
        if not enabled:
            continue
        cat_prefix = _s3_join(prefix, "drive", category_dir) + "/"
        keys = _list_s3_keys(client, bucket, cat_prefix, (".html", ".htm"))
        for key in keys:
            fname = key.rsplit("/", 1)[-1]
            meta = lookup.get(fname, {})
            records.append({
                "source": "s3",
                "path": "",
                "s3_key": key,
                "ticker": meta.get("ticker", ""),
                "cik": str(meta.get("cik", "")),
                "company": meta.get("company", ""),
                "filing_type": meta.get("filing_type", category_dir),
                "filing_date": meta.get("filing_date", ""),
                "accession": meta.get("accession", ""),
                "category": category_dir,
            })
        logger.info("S3 %s: %d objects under s3://%s/%s", category_dir, len(keys), bucket, cat_prefix)

    if PROCESS_FACTSHEETS:
        fs_prefix = _s3_join(prefix, "factsheets") + "/"
        keys = _list_s3_keys(client, bucket, fs_prefix, (".md",))
        for key in keys:
            fname = key.rsplit("/", 1)[-1]
            stem = fname[:-3] if fname.endswith(".md") else fname
            parts = stem.split("_")
            ticker = parts[0] if len(parts) >= 2 else ""
            cik = parts[1] if len(parts) >= 2 else ""
            records.append({
                "source": "s3",
                "path": "",
                "s3_key": key,
                "ticker": ticker,
                "cik": cik,
                "company": "",
                "filing_type": "factsheet",
                "filing_date": "",
                "accession": "",
                "category": "factsheet",
            })
        logger.info("S3 factsheets: %d objects under s3://%s/%s", len(keys), bucket, fs_prefix)

    logger.info("Collected %d S3 inputs from s3://%s/%s", len(records), bucket, prefix)
    return records


def collect_inputs() -> List[Dict[str, str]]:
    """Collect inputs from S3 or the local filesystem based on INPUT_SOURCE."""
    if INPUT_SOURCE == "local":
        return collect_local_inputs(INPUT_PATH, MANIFEST_PATH, FACTSHEET_DIR)
    if INPUT_SOURCE == "s3":
        return collect_s3_inputs(S3_BUCKET, S3_PREFIX)
    raise ValueError(f"Unsupported INPUT_SOURCE={INPUT_SOURCE!r}; use 's3' or 'local'")


def collect_filing_inputs(input_path: str, manifest_path: str) -> List[Dict[str, str]]:
    """Backward-compatible local collector for callers of the original API."""
    return collect_local_inputs(input_path, manifest_path, FACTSHEET_DIR)


# ---------------------------------------------------------------------------
# Stage 1: Parse with Docling + chunk
# ---------------------------------------------------------------------------

class DoclingChunkActor:
    """Parse HTML/MD with Docling and chunk with HybridChunker.

    For S3 records, downloads each object to actor-local /tmp, parses it,
    then deletes the temp file.
    """

    def __init__(self):
        from docling.chunking import HybridChunker
        from docling.datamodel.base_models import InputFormat
        from docling.document_converter import DocumentConverter

        os.environ["TOKENIZERS_PARALLELISM"] = "false"

        self.converter = DocumentConverter(
            allowed_formats=[InputFormat.HTML, InputFormat.MD]
        )
        self.chunker = HybridChunker(
            tokenizer=EMBEDDING_MODEL, max_tokens=CHUNK_MAX_TOKENS
        )
        self.docs_processed = 0
        self.docs_failed = 0
        self._s3 = None
        logger.info("DoclingChunkActor ready")

    def _client(self):
        if self._s3 is None:
            self._s3 = _s3_client()
        return self._s3

    def _resolve_local_path(self, source: str, path: str, s3_key: str) -> tuple[str, Optional[str]]:
        """Return (local_path, temp_path_to_delete_or_None)."""
        if source == "s3" or s3_key:
            suffix = Path(s3_key).suffix or ".bin"
            fd, tmp_path = tempfile.mkstemp(prefix="edgar-", suffix=suffix, dir="/tmp")
            os.close(fd)
            download_s3_object(self._client(), S3_BUCKET, s3_key, tmp_path)
            return tmp_path, tmp_path
        return path, None

    def __call__(self, batch: Dict[str, List]) -> Dict[str, List]:
        out: Dict[str, List[Any]] = {
            "text": [], "source_file": [], "chunk_index": [],
            "ticker": [], "cik": [], "company": [],
            "filing_type": [], "filing_date": [], "accession": [],
            "category": [], "parse_time_s": [],
        }

        n = len(batch["s3_key"]) if "s3_key" in batch else len(batch["path"])
        for i in range(n):
            source = batch.get("source", ["local"] * n)[i]
            path = batch.get("path", [""] * n)[i]
            s3_key = batch.get("s3_key", [""] * n)[i]
            fname = os.path.basename(s3_key or path)
            tmp_to_delete: Optional[str] = None

            try:
                local_path, tmp_to_delete = self._resolve_local_path(source, path, s3_key)
                if not os.path.isfile(local_path):
                    logger.warning("File not found: %s", fname)
                    self.docs_failed += 1
                    continue

                t0 = time.time()
                result = self.converter.convert(local_path)
                doc = result.document
                parse_time = time.time() - t0

                chunks = [c for c in self.chunker.chunk(doc) if c.text.strip()]

                for idx, chunk in enumerate(chunks):
                    out["text"].append(chunk.text)
                    out["source_file"].append(fname)
                    out["chunk_index"].append(idx)
                    out["ticker"].append(batch["ticker"][i])
                    out["cik"].append(batch["cik"][i])
                    out["company"].append(batch["company"][i])
                    out["filing_type"].append(batch["filing_type"][i])
                    out["filing_date"].append(batch["filing_date"][i])
                    out["accession"].append(batch["accession"][i])
                    out["category"].append(batch["category"][i])
                    out["parse_time_s"].append(parse_time)

                self.docs_processed += 1
                logger.info("%s: %d chunks (%.1fs)", fname, len(chunks), parse_time)

            except Exception as e:
                self.docs_failed += 1
                logger.error("Failed to parse %s: %s", fname, str(e)[:200])
            finally:
                if tmp_to_delete and os.path.isfile(tmp_to_delete):
                    try:
                        os.unlink(tmp_to_delete)
                    except OSError:
                        pass

        return out


# ---------------------------------------------------------------------------
# Stage 2: Embed with sentence-transformers (CPU)
# ---------------------------------------------------------------------------

class EmbedActor:
    """Generate embeddings using sentence-transformers."""

    def __init__(self):
        from sentence_transformers import SentenceTransformer

        self.model = SentenceTransformer(EMBEDDING_MODEL)
        actual_dim = self.model.get_sentence_embedding_dimension()
        if actual_dim != EMBEDDING_DIM:
            raise ValueError(
                f"Model '{EMBEDDING_MODEL}' produces {actual_dim}-dim embeddings "
                f"but EMBEDDING_DIM is {EMBEDDING_DIM}"
            )
        logger.info("EmbedActor ready (%s, dim=%d)", EMBEDDING_MODEL, EMBEDDING_DIM)

    def __call__(self, batch: Dict[str, List]) -> Dict[str, List]:
        texts = list(batch["text"])
        t0 = time.time()
        embeddings = self.model.encode(texts, normalize_embeddings=True)
        elapsed = time.time() - t0

        result = {k: list(v) for k, v in batch.items()}
        result["embedding"] = [emb.tolist() for emb in embeddings]
        result["embed_time_s"] = [elapsed / len(texts)] * len(texts)
        return result


# ---------------------------------------------------------------------------
# Stage 3: Insert into Milvus
# ---------------------------------------------------------------------------

class MilvusWriteActor:
    """Insert embeddings and metadata into Milvus."""

    def __init__(self):
        from pymilvus import MilvusClient

        self.milvus = MilvusClient(
            uri=f"http://{MILVUS_HOST}:{MILVUS_PORT}", db_name=MILVUS_DB
        )
        self.total_inserted = 0
        logger.info("MilvusWriteActor ready")

    def __call__(self, batch: Dict[str, List]) -> Dict[str, List]:
        texts = list(batch["text"])
        t0 = time.time()
        inserted = 0

        for i in range(0, len(texts), MILVUS_BATCH_SIZE):
            end = min(i + MILVUS_BATCH_SIZE, len(texts))
            data = []
            for j in range(i, end):
                text = str(texts[j])
                if len(text) > MILVUS_TEXT_MAX_CHARS:
                    text = text[:MILVUS_TEXT_MAX_CHARS]

                data.append({
                    "source_file": str(batch["source_file"][j]),
                    "chunk_index": int(batch["chunk_index"][j]),
                    "text": text,
                    "ticker": str(batch["ticker"][j]),
                    "cik": str(batch["cik"][j]),
                    "filing_type": str(batch["filing_type"][j]),
                    "filing_date": str(batch["filing_date"][j]),
                    "category": str(batch["category"][j]),
                    "embedding": list(batch["embedding"][j]),
                })

            for attempt in range(3):
                try:
                    self.milvus.insert(collection_name=COLLECTION_NAME, data=data)
                    break
                except (TypeError, ValueError):
                    raise
                except Exception:
                    if attempt == 2:
                        raise
                    time.sleep(2 ** attempt)
            inserted += len(data)

        elapsed = time.time() - t0
        self.total_inserted += inserted
        logger.info("Inserted %d vectors (%.1fs)", inserted, elapsed)

        return {
            "chunks_inserted": [1] * len(texts),
            "source_file": list(batch["source_file"]),
        }


# ---------------------------------------------------------------------------
# Milvus collection setup
# ---------------------------------------------------------------------------

def setup_milvus_collection():
    """Create the Milvus collection with metadata fields for filtered search."""
    from pymilvus import CollectionSchema, DataType, FieldSchema, MilvusClient

    client = MilvusClient(uri=f"http://{MILVUS_HOST}:{MILVUS_PORT}", db_name=MILVUS_DB)

    if client.has_collection(COLLECTION_NAME):
        if DROP_EXISTING_COLLECTION:
            logger.info("Dropping existing collection '%s'", COLLECTION_NAME)
            client.drop_collection(COLLECTION_NAME)
        else:
            raise RuntimeError(
                f"Collection '{COLLECTION_NAME}' already exists. "
                f"Set DROP_EXISTING_COLLECTION=true to recreate."
            )

    schema = CollectionSchema(
        fields=[
            FieldSchema(name="id", dtype=DataType.INT64, is_primary=True, auto_id=True),
            FieldSchema(name="source_file", dtype=DataType.VARCHAR, max_length=512),
            FieldSchema(name="chunk_index", dtype=DataType.INT64),
            FieldSchema(name="text", dtype=DataType.VARCHAR, max_length=MILVUS_TEXT_MAX_CHARS),
            FieldSchema(name="ticker", dtype=DataType.VARCHAR, max_length=16),
            FieldSchema(name="cik", dtype=DataType.VARCHAR, max_length=16),
            FieldSchema(name="filing_type", dtype=DataType.VARCHAR, max_length=32),
            FieldSchema(name="filing_date", dtype=DataType.VARCHAR, max_length=16),
            FieldSchema(name="category", dtype=DataType.VARCHAR, max_length=16),
            FieldSchema(name="embedding", dtype=DataType.FLOAT_VECTOR, dim=EMBEDDING_DIM),
        ],
        description="SEC EDGAR filing chunks for counterparty due diligence RAG",
    )
    client.create_collection(collection_name=COLLECTION_NAME, schema=schema)

    index_params = client.prepare_index_params()
    index_params.add_index(
        field_name="embedding",
        index_type="IVF_FLAT",
        metric_type="COSINE",
        params={"nlist": 128},
    )
    client.create_index(collection_name=COLLECTION_NAME, index_params=index_params)
    logger.info("Collection '%s' created (dim=%d)", COLLECTION_NAME, EMBEDDING_DIM)


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

def run_pipeline(records: List[Dict[str, str]]) -> Dict[str, Any]:
    """Run the 3-stage streaming pipeline."""
    ds = ray.data.from_items(records)
    target_blocks = max(1, NUM_DOCLING_ACTORS * 2)
    ds = ds.repartition(num_blocks=target_blocks, shuffle=False)

    logger.info(
        "Pipeline: docling=%dx%dCPU, embed=%dx2CPU, milvus=%dx1CPU",
        NUM_DOCLING_ACTORS, CPUS_PER_DOCLING_ACTOR,
        NUM_EMBED_ACTORS, NUM_MILVUS_ACTORS,
    )

    ds = ds.map_batches(
        DoclingChunkActor,
        concurrency=NUM_DOCLING_ACTORS,
        batch_size=DOCLING_BATCH_SIZE,
        num_cpus=CPUS_PER_DOCLING_ACTOR,
    )

    ds = ds.map_batches(
        EmbedActor,
        concurrency=NUM_EMBED_ACTORS,
        batch_size=EMBED_BATCH_SIZE,
        num_cpus=2,
    )

    results = ds.map_batches(
        MilvusWriteActor,
        concurrency=NUM_MILVUS_ACTORS,
        batch_size=MILVUS_BATCH_SIZE,
        num_cpus=1,
    )

    start = time.time()
    total_chunks = 0
    source_files = set()

    for batch in results.iter_batches(batch_size=100):
        total_chunks += sum(batch["chunks_inserted"])
        source_files.update(batch["source_file"])

    wall_clock = time.time() - start
    total_docs = len(source_files)

    return {
        "total_documents": total_docs,
        "total_chunks": total_chunks,
        "wall_clock_s": round(wall_clock, 2),
        "docs_per_sec": round(total_docs / wall_clock, 2) if wall_clock > 0 else 0,
        "chunks_per_sec": round(total_chunks / wall_clock, 2) if wall_clock > 0 else 0,
        "embedding_model": EMBEDDING_MODEL,
        "embedding_dim": EMBEDDING_DIM,
        "collection": COLLECTION_NAME,
        "input_source": INPUT_SOURCE,
    }


def print_report(metrics: Dict[str, Any]):
    """Print pipeline results."""
    print("\n" + "=" * 60)
    print("EDGAR RAG INGESTION REPORT")
    print("=" * 60)
    print(f"Input source:    {metrics.get('input_source', INPUT_SOURCE)}")
    print(f"Documents:       {metrics['total_documents']}")
    print(f"Chunks:          {metrics['total_chunks']}")
    print(f"Wall clock:      {metrics['wall_clock_s']:.1f}s")
    print(f"Throughput:      {metrics['docs_per_sec']:.1f} docs/sec, {metrics['chunks_per_sec']:.1f} chunks/sec")
    print(f"Embedding:       {metrics['embedding_model']} (dim={metrics['embedding_dim']})")
    print(f"Milvus:          {metrics['collection']}")
    print("=" * 60)
    print(f"\nMETRICS_JSON={json.dumps(metrics)}")


def run():
    records = collect_inputs()
    if not records:
        where = f"s3://{S3_BUCKET}/{S3_PREFIX}" if INPUT_SOURCE == "s3" else INPUT_PATH
        print(f"No filings found under {where}")
        return

    legal_count = sum(1 for r in records if r["category"] == "legal")
    compliance_count = sum(1 for r in records if r["category"] == "compliance")
    factsheet_count = sum(1 for r in records if r["category"] == "factsheet")
    tickers = set(r["ticker"] for r in records if r["ticker"])
    print(
        f"Processing {len(records)} inputs "
        f"({legal_count} legal, {compliance_count} compliance, {factsheet_count} factsheets) "
        f"via INPUT_SOURCE={INPUT_SOURCE}"
    )
    print(f"Companies: {len(tickers)} ({', '.join(sorted(tickers)[:10])}{'...' if len(tickers) > 10 else ''})")

    setup_milvus_collection()
    metrics = run_pipeline(records)
    print_report(metrics)


if __name__ == "__main__":
    ray.init(ignore_reinit_error=True)
    run()
