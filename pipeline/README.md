# EDGAR RAG Pipeline

Distributed RAG ingestion pipeline for SEC EDGAR filings, adapted from the
[Red Hat AI examples](https://github.com/red-hat-data-services/red-hat-ai-examples/tree/main/examples/ray/data/rag/ray-data-pipeline).

## Architecture

3-stage Ray Data streaming pipeline:

```
HTML filings  ─┐
               ├→ [Docling parse + chunk] → [sentence-transformers embed] → [Milvus insert]
Fact sheets   ─┘
```

Each stage runs as parallel Ray actors. Downstream stages start as soon as
upstream blocks are available (streaming execution).

Two input types land in the same collection:

- **Filings** — EX-10 exhibits and 10-K/10-Q/8-K HTML from `data/seed/drive`.
- **Fact sheets** — Markdown summaries rendered from the structured XBRL
  SUB/NUM tables by `factsheet.py`. These give the retriever clean,
  tabular financials that are hard to extract reliably from filing prose.

## Differences from the Reference Example


| Aspect          | Reference                                 | This Pipeline                                              |
| --------------- | ----------------------------------------- | ---------------------------------------------------------- |
| Input format    | PDF                                       | HTML (SEC EDGAR filings) + Markdown fact sheets            |
| Metadata        | source_file only                          | ticker, CIK, filing_type, filing_date, accession, category |
| Embedding       | vLLM (GPU) or sentence-transformers (CPU) | sentence-transformers (CPU) — GPU mode can be added        |
| Milvus schema   | 4 fields                                  | 10 fields (metadata enables filtered search)               |
| Query filters   | None                                      | ticker, filing_type, category                              |
| Input discovery | Flat PDF directory                        | Seed manifest with provenance metadata                     |




## Files


| File                    | Description                                           |
| ----------------------- | ----------------------------------------------------- |
| `edgar_rag_pipeline.py` | RayJob entrypoint — 3-stage ingestion pipeline        |
| `factsheet.py`          | Renders SUB/NUM XBRL data into Markdown fact sheets   |
| `rag_query.py`          | Query helpers — search with metadata filters, LLM Q&A |
| `requirements.txt`      | Python dependencies                                   |




## Usage

### Prerequisites

- Ray cluster (or `ray start --head` for local testing)
- Milvus instance accessible from the Ray workers
- Seed corpus generated (`make seed` or `make seed-quick`)



### Generate Fact Sheets

The seed corpus ships the SEC Financial Statement Data Sets as `sub.tsv`
(submissions) and `num.tsv` (numeric facts). `factsheet.py` joins them by
accession number and renders one Markdown fact sheet per company:

```bash
python -m pipeline.factsheet                        # all companies
python -m pipeline.factsheet --ticker AAPL          # one company
python -m pipeline.factsheet --ticker AAPL --year 2023
```

Output lands in `data/seed/factsheets/<TICKER>_<CIK>.md` (49 sheets from the
current seed corpus). Each sheet covers the company's most recent 10-K:

- Header — CIK, SIC, headquarters, fiscal year end, filing date, accession
- Income Statement, Balance Sheet, Cash Flow Statement — XBRL tags mapped to
  human-readable labels, values scaled to K/M/B
- Quarterly Revenue Trend — revenue and net income per quarter, from the 10-Qs

Options:

| Flag         | Default                                  | Description                     |
| ------------ | ---------------------------------------- | ------------------------------- |
| `--sub`      | `data/seed/postgres/sub.tsv`             | Submissions table               |
| `--num`      | `data/seed/postgres/num.tsv`             | Numeric facts table             |
| `--output`   | `data/seed/factsheets`                   | Output directory                |
| `--ticker`   | all                                      | Filter to one ticker            |
| `--year`     | most recent                              | Filter to one fiscal year       |
| `--manifest` | `data/seed/manifests/seed-manifest.json` | Ticker→CIK map for filenames    |

A filing reports both the current period and the prior-year comparative under
the same XBRL tag, so the renderer keeps only the row with the latest `ddate`
per tag. Values are selected from unsegmented rows (`qtrs` 0 or 4 for annual,
1 for quarterly) to exclude business-segment breakdowns.

Run this before the pipeline if `PROCESS_FACTSHEETS` is enabled.

### Run the Pipeline

```bash
# Set Milvus connection (on-cluster defaults work if Milvus is deployed)
export MILVUS_HOST=localhost
export MILVUS_PORT=19530

# Point to seed data
export INPUT_PATH=data/seed/drive
export MANIFEST_PATH=data/seed/manifests/seed-manifest.json

# Run
python pipeline/edgar_rag_pipeline.py
```



### Configuration

All parameters are environment variables:


| Variable                 | Default                                | Description                         |
| ------------------------ | -------------------------------------- | ----------------------------------- |
| `NUM_DOCLING_ACTORS`     | 4                                      | Parallel Docling parsing actors     |
| `CPUS_PER_DOCLING_ACTOR` | 2                                      | CPUs per Docling actor              |
| `NUM_EMBED_ACTORS`       | 2                                      | Parallel embedding actors           |
| `EMBEDDING_MODEL`        | sentence-transformers/all-MiniLM-L6-v2 | sentence-transformers model         |
| `EMBEDDING_DIM`          | 384                                    | Vector dimension (must match model) |
| `CHUNK_MAX_TOKENS`       | 256                                    | Max tokens per chunk                |
| `MILVUS_HOST`            | milvus-milvus.milvus.svc.cluster.local | Milvus host                         |
| `MILVUS_COLLECTION`      | edgar_filings                          | Collection name                     |
| `PROCESS_LEGAL`          | true                                   | Include EX-10 exhibits              |
| `PROCESS_COMPLIANCE`     | true                                   | Include 10-K/10-Q/8-K filings       |
| `PROCESS_FACTSHEETS`     | true                                   | Include rendered Markdown fact sheets |
| `FACTSHEET_DIR`          | data/seed/factsheets                   | Path to rendered fact sheets        |
| `INPUT_PATH`             | data/seed/drive                        | Path to seed HTML filings           |
| `MANIFEST_PATH`          | data/seed/manifests/seed-manifest.json | Seed manifest for metadata          |




### Query

```python
from pipeline.rag_query import EdgarRAG

rag = EdgarRAG(milvus_host="localhost")

# Search with metadata filter
results = rag.search("material contracts", ticker="AAPL", category="legal")

# Full Q&A with LLM (requires OGX or vLLM endpoint)
result = rag.ask(
    "What are Apple's key commercial agreements?",
    ticker="AAPL",
    llm_endpoint="http://ogx-predictor.namespace.svc.cluster.local:8080",
)
rag.print_results(result)
```



## Milvus Collection Schema


| Field       | Type              | Description                            |
| ----------- | ----------------- | -------------------------------------- |
| id          | INT64 (auto)      | Primary key                            |
| source_file | VARCHAR(512)      | Original filename                      |
| chunk_index | INT64             | Chunk position within document         |
| text        | VARCHAR(8192)     | Chunk text content                     |
| ticker      | VARCHAR(16)       | Company ticker (e.g., AAPL)            |
| cik         | VARCHAR(16)       | SEC CIK number                         |
| filing_type | VARCHAR(32)       | Filing type (10-K, 10-Q, 8-K, EX-10.*, factsheet) |
| filing_date | VARCHAR(16)       | Filing date (empty for fact sheets)    |
| category    | VARCHAR(16)       | legal, compliance, or factsheet        |
| embedding   | FLOAT_VECTOR(384) | Normalized embedding vector            |


Index: IVF_FLAT with COSINE similarity, nlist=128.