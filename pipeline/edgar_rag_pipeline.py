"""RAG ingestion pipeline for SEC EDGAR filings.

3-stage Ray Data pipeline adapted from the Red Hat AI examples
(examples/ray/data/rag/ray-data-pipeline):
  Stage 1: DoclingChunkActor   — parse HTML filings + chunk (CPU)
  Stage 2: EmbedActor          — sentence-transformers embeddings (CPU)
  Stage 3: MilvusWriteActor    — insert vectors + metadata into Milvus

Designed to run as a RayJob on a RayCluster in RHOAI. Can also run
locally for testing with `ray start --head` + `python edgar_rag_pipeline.py`.

Input: HTML filings from the SEC EDGAR seed corpus (data/seed/drive/).
Each file's metadata (ticker, CIK, filing type) is extracted from the
directory structure and seed manifest.
"""

import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Dict, List

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

# Input path — either a PVC mount (on-cluster) or local seed directory
INPUT_PATH = os.environ.get("INPUT_PATH", "data/seed/drive")
MANIFEST_PATH = os.environ.get("MANIFEST_PATH", "data/seed/manifests/seed-manifest.json")

# Filing categories to process
PROCESS_LEGAL = os.environ.get("PROCESS_LEGAL", "true").lower() == "true"
PROCESS_COMPLIANCE = os.environ.get("PROCESS_COMPLIANCE", "true").lower() == "true"
PROCESS_FACTSHEETS = os.environ.get("PROCESS_FACTSHEETS", "true").lower() == "true"
FACTSHEET_DIR = os.environ.get("FACTSHEET_DIR", "data/seed/factsheets")


# ---------------------------------------------------------------------------
# Input collection
# ---------------------------------------------------------------------------

def collect_filing_inputs(input_path: str, manifest_path: str) -> List[Dict[str, str]]:
    """Build a list of filing records with metadata from the seed manifest.

    Each record has: path, ticker, cik, company, filing_type, filing_date, accession
    """
    manifest = {}
    if os.path.isfile(manifest_path):
        with open(manifest_path) as f:
            manifest = json.load(f)

    # Build lookup from filename -> manifest entry
    manifest_lookup = {}
    for category in ("legal", "compliance"):
        for entry in manifest.get(category, []):
            fname = entry.get("filename", "")
            if fname:
                manifest_lookup[fname] = entry

    records = []
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
            meta = manifest_lookup.get(fname, {})

            records.append({
                "path": str(html_file),
                "ticker": meta.get("ticker", ""),
                "cik": str(meta.get("cik", "")),
                "company": meta.get("company", ""),
                "filing_type": meta.get("filing_type", category_dir),
                "filing_date": meta.get("filing_date", ""),
                "accession": meta.get("accession", ""),
                "category": category_dir,
            })

    # Fact sheets (Markdown rendered from SUB/NUM structured data)
    if PROCESS_FACTSHEETS:
        fs_dir = Path(FACTSHEET_DIR)
        if fs_dir.is_dir():
            for md_file in sorted(fs_dir.glob("*.md")):
                stem = md_file.stem  # e.g. AAPL_320193 or AAPL_320193_FY2024
                parts = stem.split("_")
                ticker = parts[0] if len(parts) >= 2 else ""
                cik = parts[1] if len(parts) >= 2 else ""
                records.append({
                    "path": str(md_file),
                    "ticker": ticker,
                    "cik": cik,
                    "company": "",
                    "filing_type": "factsheet",
                    "filing_date": "",
                    "accession": "",
                    "category": "factsheet",
                })
            logger.info("Added %d fact sheets from %s",
                        sum(1 for r in records if r["category"] == "factsheet"), fs_dir)

    logger.info("Collected %d total inputs from %s", len(records), input_path)
    return records


# ---------------------------------------------------------------------------
# Stage 1: Parse HTML with Docling + chunk
# ---------------------------------------------------------------------------

class DoclingChunkActor:
    """Parse HTML filings with Docling and chunk with HybridChunker."""

    def __init__(self):
        from docling.chunking import HybridChunker
        from docling.datamodel.base_models import InputFormat
        from docling.document_converter import DocumentConverter

        os.environ["TOKENIZERS_PARALLELISM"] = "false"

        # HTML for EDGAR filings, MD for the rendered fact sheets
        self.converter = DocumentConverter(
            allowed_formats=[InputFormat.HTML, InputFormat.MD]
        )
        self.chunker = HybridChunker(
            tokenizer=EMBEDDING_MODEL, max_tokens=CHUNK_MAX_TOKENS
        )
        self.docs_processed = 0
        self.docs_failed = 0
        logger.info("DoclingChunkActor ready")

    def __call__(self, batch: Dict[str, List]) -> Dict[str, List]:
        out: Dict[str, List[Any]] = {
            "text": [], "source_file": [], "chunk_index": [],
            "ticker": [], "cik": [], "company": [],
            "filing_type": [], "filing_date": [], "accession": [],
            "category": [], "parse_time_s": [],
        }

        for i in range(len(batch["path"])):
            file_path = batch["path"][i]
            fname = os.path.basename(file_path)

            try:
                if not os.path.isfile(file_path):
                    logger.warning("File not found: %s", fname)
                    self.docs_failed += 1
                    continue

                t0 = time.time()
                result = self.converter.convert(file_path)
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

    # Stage 1: Parse HTML + chunk
    ds = ds.map_batches(
        DoclingChunkActor,
        concurrency=NUM_DOCLING_ACTORS,
        batch_size=DOCLING_BATCH_SIZE,
        num_cpus=CPUS_PER_DOCLING_ACTOR,
    )

    # Stage 2: Embed (CPU)
    ds = ds.map_batches(
        EmbedActor,
        concurrency=NUM_EMBED_ACTORS,
        batch_size=EMBED_BATCH_SIZE,
        num_cpus=2,
    )

    # Stage 3: Write to Milvus
    results = ds.map_batches(
        MilvusWriteActor,
        concurrency=NUM_MILVUS_ACTORS,
        batch_size=MILVUS_BATCH_SIZE,
        num_cpus=1,
    )

    # Consume and collect metrics
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
    }


def print_report(metrics: Dict[str, Any]):
    """Print pipeline results."""
    print("\n" + "=" * 60)
    print("EDGAR RAG INGESTION REPORT")
    print("=" * 60)
    print(f"Documents:       {metrics['total_documents']}")
    print(f"Chunks:          {metrics['total_chunks']}")
    print(f"Wall clock:      {metrics['wall_clock_s']:.1f}s")
    print(f"Throughput:      {metrics['docs_per_sec']:.1f} docs/sec, {metrics['chunks_per_sec']:.1f} chunks/sec")
    print(f"Embedding:       {metrics['embedding_model']} (dim={metrics['embedding_dim']})")
    print(f"Milvus:          {metrics['collection']}")
    print("=" * 60)
    print(f"\nMETRICS_JSON={json.dumps(metrics)}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run():
    records = collect_filing_inputs(INPUT_PATH, MANIFEST_PATH)
    if not records:
        print(f"No filings found under {INPUT_PATH}")
        return

    legal_count = sum(1 for r in records if r["category"] == "legal")
    compliance_count = sum(1 for r in records if r["category"] == "compliance")
    tickers = set(r["ticker"] for r in records if r["ticker"])
    print(f"Processing {len(records)} filings ({legal_count} legal, {compliance_count} compliance)")
    print(f"Companies: {len(tickers)} ({', '.join(sorted(tickers)[:10])}{'...' if len(tickers) > 10 else ''})")

    setup_milvus_collection()
    metrics = run_pipeline(records)
    print_report(metrics)


if __name__ == "__main__":
    ray.init(ignore_reinit_error=True)
    run()
