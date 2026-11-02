.PHONY: seed seed-quick seed-dry-run configure-rag-connectors

# Full seed: all 50 companies, 8 quarters of financial data
seed:
	python -m seed

# Quick test: 5 companies, no financial archives
seed-quick:
	python -m seed --companies 5 --skip-financial

# Dry run: discover filings without downloading anything
seed-dry-run:
	python -m seed --dry-run

# Create the RAG scenario's Airbyte sources, destinations, and connections.
# The required *_CONFIG_FILE variables must point to private JSON files.
configure-rag-connectors:
	./scripts/05-configure-rag-connectors.sh
