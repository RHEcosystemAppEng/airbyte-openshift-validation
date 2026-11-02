# RAG Airbyte connector configs

These files are templates for `scripts/05-configure-rag-connectors.sh`. Copy
them outside the repository, replace the placeholders with real values, and
pass the resulting paths through environment variables. Do not commit filled
in configs: connector files contain OAuth, service-account, or S3 credentials.

The script creates four sources and two destinations:

- Google Drive `legal/` → shared S3-compatible landing zone
- Google Drive `compliance/` → shared S3-compatible landing zone
- S3 `financial-statements/` → shared S3-compatible landing zone
- PostgreSQL SEC data → PostgreSQL landing destination

The S3 source template intentionally targets extracted `.tsv` files and
parses them as tab-delimited CSV. The seed corpus is distributed as ZIP
archives, so extract the archives into the source bucket first (or change the
template to match the actual extracted `.csv`/`.tsv` paths). Do not point the
CSV stream at `.zip` objects.

The source and destination definition IDs are configurable because the
self-managed Airbyte catalog can vary by version. The Google Drive and S3 IDs
default to the official connector definitions documented by Airbyte; override
the corresponding `*_DEF_ID` variable if the installed catalog differs.

## Configure and run

```bash
cp examples/airbyte/rag-connectors/google-drive-legal.json.example /tmp/rag-google-drive-legal.json
cp examples/airbyte/rag-connectors/google-drive-compliance.json.example /tmp/rag-google-drive-compliance.json
cp examples/airbyte/rag-connectors/s3-financial-statements.json.example /tmp/rag-s3-source.json
cp examples/airbyte/rag-connectors/postgres-sec.json.example /tmp/rag-postgres-source.json
cp examples/airbyte/rag-connectors/s3-landing-destination.json.example /tmp/rag-s3-destination.json
cp examples/airbyte/rag-connectors/postgres-landing-destination.json.example /tmp/rag-postgres-destination.json

export GDRIVE_LEGAL_CONFIG_FILE=/tmp/rag-google-drive-legal.json
export GDRIVE_COMPLIANCE_CONFIG_FILE=/tmp/rag-google-drive-compliance.json
export S3_SOURCE_CONFIG_FILE=/tmp/rag-s3-source.json
export POSTGRES_SOURCE_CONFIG_FILE=/tmp/rag-postgres-source.json
export S3_DESTINATION_CONFIG_FILE=/tmp/rag-s3-destination.json
export POSTGRES_DESTINATION_CONFIG_FILE=/tmp/rag-postgres-destination.json

./scripts/05-configure-rag-connectors.sh
```

If Airbyte is not reachable through its Route, set `AIRBYTE_URL` and
`AIRBYTE_API_TOKEN`, or let the script create a port-forward. To select a
specific workspace, set `AIRBYTE_WORKSPACE_ID`.

Before running the script, deploy and seed the PostgreSQL source, or edit
`postgres-sec.json` to point at the real SEC database. The checked-in template
uses the Phase 1 service name and `sample_data` database as safe placeholders;
it does not contain the SUB/NUM corpus. The database and required tables must
exist before stream discovery and the first sync.

The script is idempotent by resource name. Existing resources are reused; the
script does not overwrite their credentials. Update an existing connector in
the Airbyte UI or with the appropriate Public API update endpoint.

## Connector notes

The JSON shape is connector-version-specific. The templates follow the
current Airbyte fields for Google Drive, S3, and the S3 destination. In
particular, the S3 destination uses `s3_endpoint` for an external
S3-compatible service; leave it empty for AWS S3. This is separate from
Airbyte's own platform object storage configured in `helm/openshift-values.yaml`.

The Google Drive connector must be able to list the target folder. Share each
folder with the configured OAuth identity or service account. The two Google
Drive files intentionally differ only in `folder_url`, allowing legal and
compliance content to land as separate Airbyte sources while using the same
destination.
