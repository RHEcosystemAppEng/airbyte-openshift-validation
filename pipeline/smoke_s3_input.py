"""Local smoke test for S3 download + Docling parse (no Ray, no Milvus).

Exercises the real S3-compatible endpoint with one HTML filing and one
Markdown fact sheet. Requires edgar-seed credentials in the environment:

  export AWS_ACCESS_KEY_ID=...
  export AWS_SECRET_ACCESS_KEY=...
  export AWS_DEFAULT_REGION=...
  export S3_ENDPOINT=...          # optional; empty for AWS
  export S3_BUCKET=...
  export S3_PREFIX=edgar-seed     # optional

Usage:
  python -m pipeline.smoke_s3_input
"""

from __future__ import annotations

import logging
import os
import tempfile
from pathlib import Path

from pipeline.edgar_rag_pipeline import (
    S3_BUCKET,
    S3_PREFIX,
    _list_s3_keys,
    _s3_client,
    _s3_join,
    download_s3_object,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
logger = logging.getLogger("smoke-s3")


def _pick_key(client, bucket: str, prefix: str, suffixes: tuple) -> str:
    keys = _list_s3_keys(client, bucket, prefix, suffixes)
    if not keys:
        raise SystemExit(f"No objects under s3://{bucket}/{prefix} matching {suffixes}")
    return keys[0]


def _parse_with_docling(local_path: str) -> int:
    from docling.chunking import HybridChunker
    from docling.datamodel.base_models import InputFormat
    from docling.document_converter import DocumentConverter

    converter = DocumentConverter(allowed_formats=[InputFormat.HTML, InputFormat.MD])
    chunker = HybridChunker(
        tokenizer="sentence-transformers/all-MiniLM-L6-v2",
        max_tokens=256,
    )
    result = converter.convert(local_path)
    chunks = [c for c in chunker.chunk(result.document) if c.text.strip()]
    return len(chunks)


def main():
    if not S3_BUCKET:
        raise SystemExit("S3_BUCKET is required")

    client = _s3_client()
    legal_prefix = _s3_join(S3_PREFIX, "drive", "legal") + "/"
    fs_prefix = _s3_join(S3_PREFIX, "factsheets") + "/"

    html_key = _pick_key(client, S3_BUCKET, legal_prefix, (".html", ".htm"))
    md_key = _pick_key(client, S3_BUCKET, fs_prefix, (".md",))

    for label, key in (("HTML filing", html_key), ("Markdown fact sheet", md_key)):
        suffix = Path(key).suffix or ".bin"
        fd, tmp = tempfile.mkstemp(prefix="smoke-", suffix=suffix, dir="/tmp")
        os.close(fd)
        try:
            logger.info("Downloading %s: s3://%s/%s", label, S3_BUCKET, key)
            download_s3_object(client, S3_BUCKET, key, tmp)
            n = _parse_with_docling(tmp)
            logger.info("OK %s -> %d chunks", label, n)
        finally:
            if os.path.isfile(tmp):
                os.unlink(tmp)

    print("smoke_s3_input: passed")


if __name__ == "__main__":
    main()
