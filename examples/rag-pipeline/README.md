# RAG Pipeline: Airbyte + OpenShift AI

Demonstrates end-to-end Retrieval-Augmented Generation using Airbyte-synced data on OpenShift AI (RHOAI).

## Architecture

```
+------------------+       +------------------+       +------------------+
|                  |       |                  |       |                  |
|   PostgreSQL     | Sync  |    Airbyte       | Write |   PostgreSQL     |
|   (source)       +------>+   (OpenShift)    +------>+   (destination)  |
|                  |       |                  |       |   airbyte_output |
+------------------+       +------------------+       +--------+---------+
                                                               |
                                                          Read |
                                                               v
                                                      +--------+---------+
                                                      |                  |
                                                      |  RHOAI Workbench |
                                                      |  (this script)   |
                                                      |                  |
                                                      |  1. Fetch docs   |
                                                      |  2. Chunk text   |
                                                      |  3. Embed        |
                                                      |  4. Store vectors|
                                                      |  5. Search       |
                                                      |                  |
                                                      +------------------+
```

## Setup

1. Ensure Airbyte has synced data to the `airbyte_output` schema (see parent project's sync validation).

2. Create an RHOAI Workbench in the `airbyte-validation` namespace with a Standard Data Science image.

3. Install dependencies in the workbench terminal:

```bash
pip install -r requirements.txt
```

4. Run the pipeline:

```bash
python notebook.py
```

This will:
- Load all documents from `airbyte_output.documents`
- Split them into overlapping 512-character chunks
- Generate 384-dimensional embeddings using `all-MiniLM-L6-v2`
- Store embeddings in `airbyte_output.document_embeddings`
- Run sample similarity searches

## Database Connection

The script connects to PostgreSQL at `postgresql.airbyte-validation.svc.cluster.local` using the same credentials as the Airbyte destination. Edit `DB_CONFIG` in `notebook.py` if your setup differs.

## Extending This Example

- **pgvector**: If pgvector is installed, change the `embedding` column type to `vector(384)` and use `<=>` (cosine distance) for faster indexed search.
- **LLM integration**: Feed search results into a KServe-hosted LLM as context for generation.
- **Scheduled refresh**: Use Airbyte's scheduled sync + a CronJob or RHOAI Pipeline to re-index automatically.
