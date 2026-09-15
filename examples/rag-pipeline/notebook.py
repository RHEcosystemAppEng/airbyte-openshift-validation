"""
RAG Pipeline: Airbyte-synced documents -> embeddings -> similarity search

Designed to run in an RHOAI Workbench (Jupyter notebook environment).
Reads documents synced by Airbyte from PostgreSQL, generates embeddings,
stores them, and provides a similarity search interface.
"""

from __future__ import annotations

import json
import textwrap
from dataclasses import dataclass

import numpy as np
import psycopg2
import psycopg2.extras
from sentence_transformers import SentenceTransformer

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DB_CONFIG = {
    "host": "postgresql.airbyte-validation.svc.cluster.local",
    "port": 5432,
    "user": "airbyte_test",
    "password": "testpass123",
    "dbname": "sample_data",
}

SOURCE_SCHEMA = "airbyte_output"
EMBEDDING_MODEL = "all-MiniLM-L6-v2"
EMBEDDING_DIM = 384
CHUNK_SIZE = 512
CHUNK_OVERLAP = 64


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------


@dataclass
class Document:
    id: int
    title: str
    content: str
    doc_type: str


@dataclass
class Chunk:
    doc_id: int
    doc_title: str
    chunk_index: int
    text: str


@dataclass
class SearchResult:
    doc_title: str
    chunk_text: str
    similarity: float


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------


def get_connection() -> psycopg2.extensions.connection:
    return psycopg2.connect(**DB_CONFIG)


def fetch_documents(conn: psycopg2.extensions.connection) -> list[Document]:
    """Read all documents from the Airbyte-synced output table."""
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            f"SELECT id, title, content, doc_type FROM {SOURCE_SCHEMA}.documents ORDER BY id"
        )
        return [Document(**row) for row in cur.fetchall()]


def create_embeddings_table(conn: psycopg2.extensions.connection) -> None:
    """Create a table to store document chunk embeddings as JSON arrays.

    Uses a JSON column for the embedding vector so pgvector is not required.
    If pgvector is available, swap the column type to vector(384) and use
    cosine distance operators for faster search.
    """
    with conn.cursor() as cur:
        cur.execute(f"""
            CREATE TABLE IF NOT EXISTS {SOURCE_SCHEMA}.document_embeddings (
                id          SERIAL PRIMARY KEY,
                doc_id      INTEGER NOT NULL,
                doc_title   TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                chunk_text  TEXT NOT NULL,
                embedding   JSONB NOT NULL
            )
        """)
        cur.execute(f"""
            CREATE INDEX IF NOT EXISTS idx_embeddings_doc_id
            ON {SOURCE_SCHEMA}.document_embeddings (doc_id)
        """)
    conn.commit()


def store_embeddings(
    conn: psycopg2.extensions.connection,
    chunks: list[Chunk],
    embeddings: np.ndarray,
) -> int:
    """Insert chunk embeddings into PostgreSQL. Returns rows inserted."""
    with conn.cursor() as cur:
        cur.execute(f"TRUNCATE {SOURCE_SCHEMA}.document_embeddings")
        values = [
            (
                chunk.doc_id,
                chunk.doc_title,
                chunk.chunk_index,
                chunk.text,
                json.dumps(embedding.tolist()),
            )
            for chunk, embedding in zip(chunks, embeddings)
        ]
        psycopg2.extras.execute_values(
            cur,
            f"""INSERT INTO {SOURCE_SCHEMA}.document_embeddings
                (doc_id, doc_title, chunk_index, chunk_text, embedding)
                VALUES %s""",
            values,
        )
    conn.commit()
    return len(values)


def load_all_embeddings(
    conn: psycopg2.extensions.connection,
) -> tuple[list[dict[str, str | int]], np.ndarray]:
    """Load all stored embeddings for search."""
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            f"SELECT doc_title, chunk_text, embedding FROM {SOURCE_SCHEMA}.document_embeddings"
        )
        rows = cur.fetchall()

    metadata = [{"doc_title": r["doc_title"], "chunk_text": r["chunk_text"]} for r in rows]
    vectors = np.array([json.loads(r["embedding"]) for r in rows], dtype=np.float32)
    return metadata, vectors


# ---------------------------------------------------------------------------
# Text chunking
# ---------------------------------------------------------------------------


def chunk_text(text: str, chunk_size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    """Split text into overlapping chunks by character count."""
    if len(text) <= chunk_size:
        return [text]

    chunks: list[str] = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunk = text[start:end]
        if chunk.strip():
            chunks.append(chunk.strip())
        start = end - overlap
    return chunks


def build_chunks(documents: list[Document]) -> list[Chunk]:
    """Convert documents into overlapping text chunks."""
    chunks: list[Chunk] = []
    for doc in documents:
        text = f"{doc.title}\n\n{doc.content}"
        for i, piece in enumerate(chunk_text(text)):
            chunks.append(Chunk(doc_id=doc.id, doc_title=doc.title, chunk_index=i, text=piece))
    return chunks


# ---------------------------------------------------------------------------
# Embedding & search
# ---------------------------------------------------------------------------


def generate_embeddings(model: SentenceTransformer, chunks: list[Chunk]) -> np.ndarray:
    """Generate embeddings for all chunks."""
    texts = [c.text for c in chunks]
    return model.encode(texts, show_progress_bar=True, normalize_embeddings=True)


def cosine_similarity(query_vec: np.ndarray, corpus_vecs: np.ndarray) -> np.ndarray:
    """Compute cosine similarity between a query vector and a matrix of corpus vectors.

    Assumes vectors are already L2-normalized (sentence-transformers does this
    when normalize_embeddings=True).
    """
    return corpus_vecs @ query_vec


def search(
    query: str,
    model: SentenceTransformer,
    metadata: list[dict[str, str | int]],
    vectors: np.ndarray,
    top_k: int = 5,
) -> list[SearchResult]:
    """Find the most relevant document chunks for a query."""
    query_vec = model.encode([query], normalize_embeddings=True)[0]
    scores = cosine_similarity(query_vec, vectors)
    top_indices = np.argsort(scores)[::-1][:top_k]

    return [
        SearchResult(
            doc_title=str(metadata[i]["doc_title"]),
            chunk_text=str(metadata[i]["chunk_text"]),
            similarity=float(scores[i]),
        )
        for i in top_indices
    ]


# ---------------------------------------------------------------------------
# Main pipeline
# ---------------------------------------------------------------------------


def run_pipeline() -> None:
    """Execute the full RAG indexing pipeline."""
    print("=" * 60)
    print(" RAG Pipeline: Airbyte Data -> Embeddings")
    print("=" * 60)

    # 1. Load embedding model
    print("\n[1/5] Loading embedding model...")
    model = SentenceTransformer(EMBEDDING_MODEL)
    print(f"  Model: {EMBEDDING_MODEL} (dim={EMBEDDING_DIM})")

    # 2. Fetch Airbyte-synced documents
    print("\n[2/5] Fetching documents from Airbyte output...")
    conn = get_connection()
    documents = fetch_documents(conn)
    print(f"  Loaded {len(documents)} documents")
    for doc in documents[:3]:
        print(f"    - [{doc.doc_type}] {doc.title}")
    if len(documents) > 3:
        print(f"    ... and {len(documents) - 3} more")

    # 3. Chunk documents
    print("\n[3/5] Chunking documents...")
    chunks = build_chunks(documents)
    print(f"  Created {len(chunks)} chunks (size={CHUNK_SIZE}, overlap={CHUNK_OVERLAP})")

    # 4. Generate embeddings
    print("\n[4/5] Generating embeddings...")
    embeddings = generate_embeddings(model, chunks)
    print(f"  Generated {embeddings.shape[0]} embeddings of dimension {embeddings.shape[1]}")

    # 5. Store in PostgreSQL
    print("\n[5/5] Storing embeddings in PostgreSQL...")
    create_embeddings_table(conn)
    count = store_embeddings(conn, chunks, embeddings)
    print(f"  Stored {count} chunk embeddings in {SOURCE_SCHEMA}.document_embeddings")

    conn.close()
    print("\nIndexing complete.")


def run_search(queries: list[str] | None = None) -> None:
    """Run sample similarity searches against the indexed embeddings."""
    if queries is None:
        queries = [
            "How do I deploy on Kubernetes?",
            "What is the data retention policy?",
            "authentication and single sign-on",
        ]

    print("\n" + "=" * 60)
    print(" RAG Search Demo")
    print("=" * 60)

    model = SentenceTransformer(EMBEDDING_MODEL)
    conn = get_connection()
    metadata, vectors = load_all_embeddings(conn)
    conn.close()

    print(f"Loaded {len(metadata)} indexed chunks\n")

    for query in queries:
        print(f'Query: "{query}"')
        print("-" * 50)
        results = search(query, model, metadata, vectors, top_k=3)
        for rank, result in enumerate(results, 1):
            snippet = textwrap.shorten(result.chunk_text, width=120, placeholder="...")
            print(f"  {rank}. [{result.similarity:.3f}] {result.doc_title}")
            print(f"     {snippet}")
        print()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    run_pipeline()
    run_search()
