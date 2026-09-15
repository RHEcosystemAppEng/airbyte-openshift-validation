# Airbyte on OpenShift AI -- Partner Validation

**Verdict: CONDITIONAL PASS**

Airbyte 2.1.1 deploys and operates on OpenShift 4.21 alongside Red Hat OpenShift AI (RHOAI) 3.4.1 with one critical workaround required. All core platform pods run under the `restricted-v2` SCC without elevated privileges. End-to-end data ingestion was validated with 72 rows synced across 3 tables from PostgreSQL source to PostgreSQL destination. Airbyte is not yet Red Hat certified (preflight and chart-verifier both fail), and the replication orchestrator has a high-severity resource bug that requires manual intervention on resource-constrained clusters.

Report date: 2026-08-27

---

## Overview

This repository documents the validation of [Airbyte](https://airbyte.com) as a data integration partner for Red Hat OpenShift AI. Airbyte provides ELT (Extract, Load, Transform) pipelines with 400+ connectors, making it a candidate for feeding enterprise data into RHOAI workloads such as model training, RAG pipelines, and feature engineering.

The validation covers:

- **Deployment** on OpenShift 4.21.16 via Helm chart
- **Security compliance** with the `restricted-v2` Security Context Constraint
- **Coexistence** with RHOAI 3.4.1 (zero conflicts across 22 RHOAI pods)
- **End-to-end data ingestion** from PostgreSQL source to PostgreSQL destination
- **Red Hat certification readiness** via preflight and chart-verifier
- **Integration patterns** with RHOAI components (Workbenches, Pipelines, KServe)

| Component | Version |
|-----------|---------|
| OpenShift | 4.21.16 (Kubernetes 1.34.7) |
| RHOAI | 3.4.1 |
| Airbyte | 2.1.1 (Helm chart `airbyte-v2/airbyte`) |
| Namespace | `airbyte-validation` |

---

## Validation Status

| Category | Result | Notes |
|----------|--------|-------|
| Deployment on OpenShift | PASS | 10 pods Running/Completed; namespace annotation workaround required |
| restricted-v2 SCC Compliance | PASS | All pods run under restricted-v2; no custom SCCs needed |
| RHOAI Coexistence | PASS | 6/6 checks passed; zero conflicts; 22 RHOAI pods healthy |
| E2E Data Ingestion | PASS | 72 rows, 13,592 bytes, 3m 13s; replication resource workaround required |
| Preflight (container image) | FAIL | 7 pass / 3 fail (missing /licenses, required labels, not UBI-based) |
| Chart-Verifier (Helm chart) | FAIL | 8 pass / 5 fail / 1 skipped (missing values.schema.json, kubeVersion, certified images) |

**Conditional pass logic:** Airbyte is fully functional on OpenShift with RHOAI, but the overall verdict is CONDITIONAL because:

1. **One high-severity bug** -- the replication orchestrator ignores resource configuration and hardcodes 2 CPU / 2 Gi per container, causing scheduling failures on resource-constrained clusters. A manual workaround exists.
2. **Not yet Red Hat certified** -- container images are not UBI-based and the Helm chart is missing certification metadata. These are pre-certification gaps, not functional blockers.

---

## Architecture

Airbyte deploys in its own namespace alongside RHOAI with full namespace isolation. The platform pods handle orchestration, scheduling, and API serving. Connector pods (source, destination) are launched dynamically for each sync job and terminated on completion.

```
+---------------------+     +---------------------+     +---------------------+
|                     |     |                     |     |                     |
|   External Data     | Sync|      Airbyte        | Write|    PostgreSQL /    |
|   Sources           +---->+   (airbyte-         +---->+    S3 / Object     |
|                     |     |    validation ns)    |     |    Store           |
|   - PostgreSQL      |     |                     |     |                     |
|   - MySQL           |     |   restricted-v2 SCC |     +----------+----------+
|   - APIs            |     |   UID 1000          |                |
|   - SaaS            |     |   ~205m CPU         |           Read |
|   - Files           |     |   ~2.2 GiB memory   |                v
|                     |     |                     |     +----------+----------+
+---------------------+     +---------------------+     |                     |
                                                        |   RHOAI Components  |
                                                        |   (redhat-ods-      |
                                                        |    applications ns) |
                                                        |                     |
                                                        |   - Workbenches     |
                                                        |   - Pipelines       |
                                                        |   - KServe          |
                                                        |   - Model Registry  |
                                                        |                     |
                                                        +---------------------+
```

**Namespace isolation:** Airbyte runs in `airbyte-validation` with its own service accounts, RBAC, and resource quotas. RHOAI components remain in `redhat-ods-applications`. The two namespaces share no CRDs, service accounts, or cluster-scoped resources. Communication happens through the shared data layer (PostgreSQL accessed via in-cluster DNS).

**Platform pods (all under restricted-v2 SCC):**

| Pod | Role | Status |
|-----|------|--------|
| airbyte-server | API + UI (port 8001) | Running |
| airbyte-worker | Sync orchestration | Running |
| airbyte-workload-launcher | Launches connector pods | Running |
| airbyte-workload-api-server | Internal API | Running |
| airbyte-temporal | Workflow engine | Running |
| airbyte-cron | Scheduled tasks | Running |
| airbyte-manifest-server | Connector builder | Running |
| airbyte-db-0 | Bundled PostgreSQL | Running |
| airbyte-minio-0 | Bundled object storage | Running |
| airbyte-bootloader | DB migration (one-time) | Completed |

---

## Quick Start

### Prerequisites

- OpenShift 4.14+ with `oc` CLI logged in as cluster-admin
- Helm 3.x
- Default StorageClass capable of provisioning RWO PersistentVolumeClaims

```bash
# Verify prerequisites
oc whoami
oc auth can-i create namespaces --all-namespaces
helm version --short
```

### 1. Create and configure the namespace

OpenShift requires a two-step namespace creation to preserve the auto-populated MCS annotation. See [Known Issues](#finding-2-namespace-mcs-annotation-medium) for details.

```bash
# Step 1: Create namespace (lets OpenShift auto-populate MCS annotation)
oc new-project airbyte-validation \
  --display-name="Airbyte Validation" \
  --description="Airbyte on OpenShift AI partner validation"

# Step 2: Override UID/GID annotations AFTER creation
oc annotate namespace airbyte-validation \
  openshift.io/sa.scc.uid-range="1000/1" \
  openshift.io/sa.scc.supplemental-groups="1000/1" \
  --overwrite

oc label namespace airbyte-validation \
  app.kubernetes.io/part-of=airbyte-validation \
  purpose=partner-validation \
  --overwrite
```

### 2. Add the Helm repository

```bash
helm repo add airbyte-v2 https://airbytehq.github.io/charts
helm repo update airbyte-v2
```

### 3. Deploy Airbyte

```bash
helm upgrade --install airbyte airbyte-v2/airbyte \
  --namespace airbyte-validation \
  --values helm/openshift-values.yaml \
  --version 2.1.1 \
  --timeout 10m \
  --wait \
  --atomic
```

The `--atomic` flag ensures automatic rollback on failure.

### 4. Create the OpenShift Route

```bash
oc apply -f manifests/route.yaml -n airbyte-validation
```

### 5. Verify the deployment

```bash
# All 10 pods should be Running or Completed
oc get pods -n airbyte-validation

# Verify all pods run under restricted-v2 SCC
oc get pods -n airbyte-validation -o json | \
  jq -r '.items[] | "\(.metadata.name): \(.metadata.annotations["openshift.io/scc"])"'

# Get the Route URL
ROUTE=$(oc get route airbyte-server -n airbyte-validation -o jsonpath='{.spec.host}')
echo "Airbyte UI: https://${ROUTE}"

# Health check (note: V2 uses /api/public/v1/, not /api/v1/)
curl -s "https://${ROUTE}/api/public/v1/health" | jq .
```

### Automated deployment

The `scripts/` directory contains the full automation:

```bash
scripts/00-prereqs.sh           # Validate prerequisites
scripts/01-deploy-airbyte.sh    # Deploy Airbyte (idempotent)
scripts/02-verify-coexistence.sh # Run RHOAI coexistence checks
scripts/03-deploy-datasource.sh  # Deploy PostgreSQL test source
scripts/04-configure-airbyte.sh  # Configure connectors via API
scripts/06-certification-checks.sh # Run preflight + chart-verifier
scripts/07-generate-report.py    # Generate validation report
```

---

## OpenShift Configuration Reference

The full values overlay is at [`helm/openshift-values.yaml`](helm/openshift-values.yaml). Key configuration decisions are documented below.

### SCC Compliance (restricted-v2)

Every enabled component uses the same security context block to satisfy the `restricted-v2` SCC:

```yaml
podSecurityContext:
  fsGroup: 1000
  fsGroupChangePolicy: OnRootMismatch

containerSecurityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  readOnlyRootFilesystem: false   # Airbyte writes temp files at runtime
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

The namespace must be annotated with `openshift.io/sa.scc.uid-range: 1000/1` to match the UID used by all pods. `fsGroupChangePolicy: OnRootMismatch` avoids expensive recursive chown on every pod restart.

`readOnlyRootFilesystem` is set to `false` because Airbyte writes temporary files at runtime. Setting it to `true` will break the application.

### Resource Sizing

Platform pod resource requests are sized for a validation environment. Scale up for production.

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|-------------|----------------|-----------|--------------|
| server | 250m | 512Mi | 1 | 1Gi |
| worker | 250m | 512Mi | 1 | 1Gi |
| workload-launcher | 250m | 512Mi | 500m | 1Gi |
| workload-api-server | 100m | 256Mi | 250m | 512Mi |
| temporal | 250m | 512Mi | 500m | 1Gi |
| cron | 100m | 256Mi | 250m | 512Mi |
| bootloader | 100m | 256Mi | 250m | 512Mi |
| manifest-server | 100m | 256Mi | 250m | 512Mi |
| minio | 100m | 256Mi | 250m | 512Mi |

**Workload resource overrides** are critical for OpenShift. The default connector resource requests (2 CPU / 2 Gi per container) exhaust scheduler capacity on shared clusters:

```yaml
global:
  workloads:
    resources:
      useConnectorResourceDefaults: false
      mainContainer:
        cpu:
          request: "250m"
          limit: "500m"
        memory:
          request: "256Mi"
          limit: "512Mi"
      replication:
        cpu:
          request: "250m"
          limit: "500m"
        memory:
          request: "256Mi"
          limit: "512Mi"
```

**Note:** The replication orchestrator ignores these values due to a bug. See [Finding #1](#finding-1-replication-pod-hardcoded-resources-high).

**JVM configuration** ensures container-aware memory limits:

```yaml
global:
  java:
    opts:
      - "-XX:+UseContainerSupport"
      - "-XX:MaxRAMPercentage=75.0"
```

The 75% RAM percentage leaves headroom for non-heap memory and prevents OOMKill.

### Disabled Components

| Component | Why Disabled |
|-----------|-------------|
| `temporalUi` | Upstream image hardcodes `runAsUser: 0` (root); incompatible with restricted-v2 |
| `webapp` | Deprecated in V2; the server component serves the UI |
| `metrics` | Not needed for validation |
| `connectorRolloutWorker` | Not needed for validation |
| `featureflagServer` | Not needed for validation |
| `keycloak` / `keycloakSetup` | Enterprise SSO; not applicable to community edition |
| `stiggSidecar` | Enterprise only |
| `ingress` | OpenShift Routes are the standard ingress mechanism |

### Storage

The validation environment uses bundled MinIO for object storage and bundled PostgreSQL for metadata, each with 2Gi PVCs:

```yaml
global:
  storage:
    type: minio
    minio:
      accessKeyId: minio
      secretAccessKey: minio123

postgresql:
  storage:
    volumeClaimValue: 2Gi

minio:
  storage:
    volumeClaimValue: 2Gi
```

For production, replace these with:

- **Object storage:** OpenShift Data Foundation (ODF), AWS S3, or an external S3-compatible store
- **Database:** An external managed PostgreSQL instance (`global.database.type: external`)

---

## What Works

### restricted-v2 SCC Compliance

All 10 platform pods run under the `restricted-v2` SCC without any custom SCC grants:

- `runAsNonRoot: true` -- no root containers
- `runAsUser: 1000`, `runAsGroup: 1000` -- compatible with OpenShift namespace UID constraints
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`

Verified via:

```bash
oc get pods -n airbyte-validation -o json | \
  jq -r '.items[] | "\(.metadata.name): \(.metadata.annotations["openshift.io/scc"])"'
```

Every pod reports `restricted-v2`.

### RHOAI Coexistence (6/6 checks passed)

| Check | Result | Detail |
|-------|--------|--------|
| RHOAI Pod Health | PASS | 22 pods healthy in `redhat-ods-applications` |
| DataScienceCluster Components | PASS | All 12 managed components unchanged (AI Pipelines, Dashboard, KServe, Ray, Feast, Llama Stack, MLflow, Model Registry, TrustyAI, Workbenches, Trainer, Training Operator) |
| Warning Events | PASS | No Airbyte-related warnings in the cluster |
| Airbyte Pod Health | PASS | All platform pods healthy |
| Resource Audit | PASS | Airbyte: ~205m CPU / ~2.2 GiB; no contention (cluster at 56% CPU / 69% memory) |
| CRD Conflict Check | PASS | Airbyte uses no CRDs; zero conflict risk with RHOAI |

Full report: [`reports/coexistence-check.txt`](reports/coexistence-check.txt)

### E2E Data Ingestion

A full sync job completed successfully:

| Metric | Value |
|--------|-------|
| Job ID | 6 |
| Status | succeeded |
| Rows synced | 72 |
| Bytes synced | 13,592 |
| Duration | 3m 13s |
| Source | PostgreSQL 16 (`registry.redhat.io/rhel9/postgresql-16`) |
| Destination | PostgreSQL (`airbyte_output` schema) |

Streams synced:

| Stream | Rows |
|--------|------|
| customers | 10 |
| documents | 17 |
| metadata | 45 |

The connection was created and triggered via the Airbyte Public API (`/api/public/v1/`). Full results: [`reports/sync-results.json`](reports/sync-results.json)

### Additional Positives

- **Low resource footprint:** ~205m CPU / ~2.2 GiB for all platform pods
- **No CRDs installed:** Airbyte uses only standard Kubernetes resources (Deployments, Services, StatefulSets), eliminating CRD conflict risk
- **Helm chart passes lint:** Clean `helm lint` with tests, README, and NOTES.txt present
- **RunAsNonRoot preflight check passes:** Critical for OpenShift restricted-v2 compatibility

---

## Known Issues and Workarounds

### Finding #1: Replication Pod Hardcoded Resources (HIGH)

**Severity:** HIGH

**Problem:** The Airbyte replication orchestrator hardcodes container resource requests at 2 CPU / 2 Gi per container (init, orchestrator, source, destination) regardless of Helm values configuration. A replication pod with 4 containers requests 8 CPU total, exceeding available capacity on typical OpenShift worker nodes.

**Evidence chain:**

1. `global.workloads.resources.useConnectorResourceDefaults: false` is set in Helm values
2. `global.workloads.resources.replication.cpu.request: "250m"` is set
3. ConfigMap `airbyte-airbyte-env` correctly contains `REPLICATION_ORCHESTRATOR_CPU_REQUEST=250m`
4. The workload-launcher pod env vars correctly read `250m`
5. Despite all of this, replication pods launch with 2 CPU / 2 Gi per container

**Impact:** Replication pods fail to schedule with `Insufficient cpu` on resource-constrained clusters, which is the norm for shared OpenShift environments.

**Root cause:** The replication orchestrator builds pod specs with hardcoded resource values instead of reading from the environment variables that the Helm chart populates (`REPLICATION_ORCHESTRATOR_CPU_REQUEST`, `REPLICATION_ORCHESTRATOR_MEMORY_REQUEST`, etc.). The workload-launcher reads these values correctly, but the downstream orchestrator code path ignores them.

**Workaround:** When a replication pod is stuck in Pending with "Insufficient cpu", export the pod spec, modify resources, and recreate:

```bash
POD_NAME="replication-job-<N>-attempt-0"

# Export the pending pod spec
oc get pod "${POD_NAME}" -n airbyte-validation -o json > /tmp/pod-fix.json

# Reduce resource requests for all containers
python3 -c "
import json
with open('/tmp/pod-fix.json') as f:
    pod = json.load(f)
pod.pop('status', None)
pod['metadata'] = {k: pod['metadata'][k] for k in ['name','namespace','labels','annotations'] if k in pod['metadata']}
pod['metadata'].pop('resourceVersion', None)
pod['metadata'].pop('uid', None)
pod['metadata'].pop('creationTimestamp', None)
pod['spec'].pop('nodeName', None)
for c in pod['spec'].get('initContainers', []):
    c['resources'] = {'requests': {'cpu': '250m', 'memory': '512Mi'}, 'limits': {'cpu': '500m', 'memory': '1Gi'}}
for c in pod['spec']['containers']:
    c['resources'] = {'requests': {'cpu': '250m', 'memory': '512Mi'}, 'limits': {'cpu': '500m', 'memory': '1Gi'}}
with open('/tmp/pod-fix.json', 'w') as f:
    json.dump(pod, f)
"

# Delete the stuck pod and recreate with fixed resources
oc delete pod "${POD_NAME}" -n airbyte-validation --force --grace-period=0
oc apply -f /tmp/pod-fix.json
```

**Env vars that should be honored (but are not):**

- `REPLICATION_ORCHESTRATOR_CPU_REQUEST` / `REPLICATION_ORCHESTRATOR_CPU_LIMIT`
- `REPLICATION_ORCHESTRATOR_MEMORY_REQUEST` / `REPLICATION_ORCHESTRATOR_MEMORY_LIMIT`
- `JOB_MAIN_CONTAINER_CPU_REQUEST` / `JOB_MAIN_CONTAINER_CPU_LIMIT`
- `JOB_MAIN_CONTAINER_MEMORY_REQUEST` / `JOB_MAIN_CONTAINER_MEMORY_LIMIT`

---

### Finding #2: Namespace MCS Annotation (MEDIUM)

**Severity:** MEDIUM

**Problem:** OpenShift auto-populates the `openshift.io/sa.scc.mcs` (Multi-Category Security) annotation when a namespace is created. If you apply a namespace manifest via `oc apply -f` that includes UID/GID annotations, OpenShift does not auto-populate the MCS annotation. Pods then fail to schedule because the SCC admission controller cannot determine the correct SELinux context.

**Impact:** Pods fail SCC validation and cannot be scheduled.

**This is an OpenShift behavior, not an Airbyte issue.**

**Fix:** Always use the two-step namespace creation:

```bash
# Step 1: Create namespace (auto-populates MCS annotation)
oc new-project airbyte-validation

# Step 2: Override UID/GID annotations AFTER creation
oc annotate namespace airbyte-validation \
  openshift.io/sa.scc.uid-range="1000/1" \
  openshift.io/sa.scc.supplemental-groups="1000/1" \
  --overwrite
```

The deploy script (`scripts/01-deploy-airbyte.sh`) handles this automatically.

---

### Finding #3: API Version Change -- V1 to Public V1 (LOW)

**Severity:** LOW

**Problem:** Airbyte V2 uses `/api/public/v1/` as the API base path. The old `/api/v1/` internal API returns 404. Any automation or monitoring that calls the Airbyte API must be updated.

**Endpoint mapping:**

| Operation | V1 (old, returns 404) | V2 (current) |
|-----------|----------------------|--------------|
| List workspaces | `POST /api/v1/workspaces/list` | `GET /api/public/v1/workspaces` |
| Create source | `POST /api/v1/sources/create` | `POST /api/public/v1/sources` |
| Create destination | `POST /api/v1/destinations/create` | `POST /api/public/v1/destinations` |
| Create connection | `POST /api/v1/connections/create` | `POST /api/public/v1/connections` |
| Trigger sync | `POST /api/v1/connections/sync` | `POST /api/public/v1/jobs` |
| Get job status | `POST /api/v1/jobs/get` | `GET /api/public/v1/jobs/{jobId}` |

---

### Finding #4: Temporal UI Requires Root (LOW)

**Severity:** LOW

**Problem:** The upstream Temporal UI image hardcodes `runAsUser: 0` (root), which is incompatible with the `restricted-v2` SCC.

**Fix:** Keep `temporalUi.enabled: false` in the values overlay. If Temporal UI access is needed for debugging, grant the `anyuid` SCC to its service account (not recommended for production).

---

## Certification Status

Airbyte is **not yet Red Hat certified**. Both preflight (container image) and chart-verifier (Helm chart) fail with pre-certification gaps. These are metadata and packaging issues, not functional blockers.

### Preflight -- Container Image (7 pass / 3 fail)

Tool: `openshift-preflight 1.21.0` against `docker.io/airbyte/server:2.1.1`

| Check | Result | Detail |
|-------|--------|--------|
| HasUniqueTag | PASS | Tag `2.1.1` (not `latest`) |
| LayerCountAcceptable | PASS | Under 40 layers |
| HasNoProhibitedPackages | PASS | No RHEL kernel packages |
| HasNoProhibitedLabels | PASS | No Red Hat trademark violations |
| RunAsNonRoot | PASS | Runs as `airbyte:airbyte` |
| HasModifiedFiles | PASS | No modified RPM files |
| HasProhibitedContainerName | PASS | No trademark violations |
| HasLicense | **FAIL** | No `/licenses` directory in image |
| HasRequiredLabel | **FAIL** | Missing: `name`, `vendor`, `version`, `release`, `summary`, `description`, `maintainer` |
| BasedOnUbi | **FAIL** | Image not based on UBI/RHHI |

The `RunAsNonRoot` pass is the most critical result for OpenShift compatibility.

### Chart-Verifier -- Helm Chart (8 pass / 5 fail / 1 skipped)

Tool: `chart-verifier 1.16.0` against `airbyte-2.1.1.tgz`, profile `partner v1.3`

| Check | Result | Detail |
|-------|--------|--------|
| contains-test | PASS | Test files present |
| has-notes | PASS | NOTES.txt present |
| not-contains-crds | PASS | No CRDs |
| has-readme | PASS | README present |
| helm-lint | PASS | Lint clean |
| contains-values | PASS | values.yaml present |
| is-helm-v3 | PASS | API version v2 |
| not-contain-csi-objects | PASS | No CSI objects |
| contains-values-schema | **FAIL** | No `values.schema.json` |
| has-kubeversion | **FAIL** | `kubeVersion` not in Chart.yaml |
| images-are-certified | **FAIL** | 0 of 11 images Red Hat certified |
| chart-testing | **FAIL** | Requires live cluster (ran in podman) |
| required-annotations-present | **FAIL** | Missing `charts.openshift.io/name` |
| signature-is-valid | SKIPPED | Chart unsigned |

### What Needs to Happen for Certification

**Container images:**

1. Rebase all Dockerfiles on `registry.access.redhat.com/ubi9/ubi-minimal:latest` (or `ubi9/openjdk-21-runtime` for JVM services)
2. Add a `/licenses` directory containing the Apache 2.0 license text and third-party notices
3. Add required OCI labels to each Dockerfile:

```dockerfile
LABEL name="airbyte-server" \
      vendor="Airbyte" \
      version="2.1.1" \
      release="1" \
      summary="Airbyte data integration server" \
      description="Airbyte server component for data integration pipelines" \
      maintainer="Airbyte <support@airbyte.io>" \
      io.k8s.display-name="Airbyte Server" \
      io.openshift.tags="airbyte,data-integration,etl"
```

4. Submit images to the Red Hat Connect portal for certification scanning
5. Publish certified images to `registry.connect.redhat.com`

**Helm chart:**

1. Generate and include `values.schema.json`
2. Add `kubeVersion` to Chart.yaml:

```yaml
kubeVersion: ">=1.26.0-0"
```

3. Add OpenShift annotation to Chart.yaml:

```yaml
annotations:
  charts.openshift.io/name: airbyte
```

4. Sign the chart with a GPG key and publish the provenance file alongside the `.tgz`

Full results: [`reports/certification-results.json`](reports/certification-results.json)

---

## Integration with OpenShift AI

Airbyte serves as the data ingestion layer that feeds enterprise data into RHOAI workloads. The integration pattern uses PostgreSQL as the shared data layer between Airbyte and RHOAI components.

### Data Flow

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
                                                      |                  |
                                                      |  1. Fetch docs   |
                                                      |  2. Chunk text   |
                                                      |  3. Embed        |
                                                      |  4. Store vectors|
                                                      |  5. Search       |
                                                      |                  |
                                                      +------------------+
```

### RAG Pipeline Example

The [`examples/rag-pipeline/`](examples/rag-pipeline/) directory contains a complete RAG (Retrieval-Augmented Generation) indexing and search pipeline designed to run in an RHOAI Workbench:

1. **Load embedding model** -- `all-MiniLM-L6-v2` from sentence-transformers (384-dimensional embeddings)
2. **Fetch Airbyte-synced documents** -- reads from `airbyte_output.documents` via in-cluster PostgreSQL DNS (`postgresql.airbyte-validation.svc.cluster.local`)
3. **Chunk text** -- 512-character chunks with 64-character overlap; document title prepended to content
4. **Generate embeddings** -- L2-normalized vectors for cosine similarity via dot product
5. **Store embeddings** -- written to `airbyte_output.document_embeddings` as JSONB arrays (no pgvector dependency required)

The pipeline connects to PostgreSQL using the same credentials as the Airbyte destination, with no external networking required.

**pgvector upgrade path:** For production workloads, change the embedding column to `vector(384)` and use the `<=>` cosine distance operator for indexed vector search, replacing the brute-force numpy dot product.

### RHOAI Components That Can Consume Airbyte Data

| Component | Integration Pattern |
|-----------|-------------------|
| **Workbenches** | Demonstrated. Python scripts/Jupyter notebooks connect directly to the Airbyte destination database for data exploration, feature engineering, and RAG indexing. |
| **Data Science Pipelines** | Use Airbyte scheduled sync + a RHOAI Pipeline to automate re-indexing after each data sync. |
| **KServe** | Feed search results from the embedding store into a KServe-hosted LLM as context for RAG generation. |
| **Model Registry** | Track models trained on Airbyte-synced datasets with lineage back to the source systems. |

### Integration Patterns

- **Shared data layer:** PostgreSQL serves as the integration point. Airbyte writes to `airbyte_output` schema; RHOAI workloads read from and write back to the same schema.
- **In-cluster service discovery:** The RHOAI workbench connects via Kubernetes DNS (`postgresql.airbyte-validation.svc.cluster.local`). No external endpoints or load balancers needed.
- **Schema separation:** Source data in default schema; synced data in `airbyte_output`. Keeps the pipeline output isolated without separate database instances.
- **Shared credentials:** The workbench uses the same database credentials as the Airbyte destination connector.

### Seed Data

The test dataset ([`data/seed.sql`](data/seed.sql)) contains 72 rows across 3 tables:

| Table | Rows | Purpose |
|-------|------|---------|
| `documents` | 17 | Enterprise docs across 7 categories (product-docs, knowledge-base, meeting-notes, architecture, runbook, policy, internal-faq) |
| `metadata` | 45 | Key-value pairs (category, audience, status, priority, compliance tags) with foreign keys to documents |
| `customers` | 10 | Customer records with tiered access (4 enterprise, 4 pro, 2 free) |

---

## Remediation Roadmap

### Airbyte Upstream Fixes

These require changes to the Airbyte codebase or build pipeline.

#### 1. Replication orchestrator resource bug (HIGH)

**What:** Replace hardcoded resource values (2 CPU / 2 Gi per container) in the replication orchestrator with reads from environment variables.

**Where:** The pod-spec construction in the replication orchestrator module (likely `container-orchestrator` or `workload-launcher`).

**How:** The workload-launcher already reads these env vars correctly. The replication orchestrator must do the same:

- `REPLICATION_ORCHESTRATOR_CPU_REQUEST` / `_LIMIT`
- `REPLICATION_ORCHESTRATOR_MEMORY_REQUEST` / `_LIMIT`
- `JOB_MAIN_CONTAINER_CPU_REQUEST` / `_LIMIT`
- `JOB_MAIN_CONTAINER_MEMORY_REQUEST` / `_LIMIT`

#### 2. UBI-based container images

Rebase all Dockerfiles on `ubi9/ubi-minimal` (or `ubi9/openjdk-21-runtime` for JVM services). Add `/licenses` directory and required OCI labels. Submit to Red Hat Connect for certification.

#### 3. Helm chart certification metadata

- Add `values.schema.json` (generate from `values.yaml` via `helm-schema-gen` or similar)
- Add `kubeVersion: ">=1.26.0-0"` to `Chart.yaml`
- Add `charts.openshift.io/name: airbyte` annotation to `Chart.yaml`
- Sign the chart with a GPG key

### Deployer Configuration

These are steps that OpenShift administrators must take when deploying Airbyte.

#### 1. Namespace setup

Use the two-step creation process (see [Quick Start](#1-create-and-configure-the-namespace)). Never apply the namespace manifest directly with UID/GID annotations -- it prevents MCS annotation auto-population.

#### 2. API version

All Airbyte V2 API calls must use `/api/public/v1/` as the base path. The old `/api/v1/` returns 404.

#### 3. Disabled components

Keep `temporalUi.enabled: false` unless you are willing to grant a custom SCC. Keep `webapp.enabled: false` (deprecated in V2).

#### 4. Production hardening

| Area | Validation Setting | Production Recommendation |
|------|--------------------|---------------------------|
| Authentication | `global.auth.enabled: false` | Enable with OIDC or built-in auth |
| Telemetry | `global.tracking.enabled: false` | Enable if not air-gapped |
| Database | Bundled PostgreSQL (2Gi PVC) | External managed PostgreSQL |
| Object storage | Bundled MinIO (2Gi PVC) | ODF, S3, or external S3-compatible store |
| Resource sizing | Minimal requests (100-250m CPU) | Scale per workload requirements |
| TLS | Edge termination at router | Consider passthrough or re-encrypt for sensitive data |
| Node selectors | Cleared (`global.topology.*: ""`) | Set to dedicated node pools |

---

## Repository Structure

```
airbyte-openshift-validation/
|-- helm/
|   +-- openshift-values.yaml          # Helm values overlay for OpenShift restricted-v2
|-- manifests/
|   |-- namespace.yaml                 # Reference only -- use two-step creation
|   |-- postgresql.yaml                # PostgreSQL test data source deployment
|   +-- route.yaml                     # OpenShift Route for Airbyte server (port 8001, edge TLS)
|-- data/
|   +-- seed.sql                       # 72 rows across 3 tables (documents, metadata, customers)
|-- scripts/
|   |-- 00-prereqs.sh                  # Validate oc, helm, cluster-admin, StorageClass
|   |-- 01-deploy-airbyte.sh           # Deploy Airbyte via Helm (idempotent)
|   |-- 02-verify-coexistence.sh       # Run 6 RHOAI coexistence checks
|   |-- 03-deploy-datasource.sh        # Deploy PostgreSQL test source with seed data
|   |-- 04-configure-airbyte.sh        # Create source, destination, connection via API
|   |-- 06-certification-checks.sh     # Run openshift-preflight and chart-verifier
|   +-- 07-generate-report.py          # Generate structured validation report
|-- examples/
|   +-- rag-pipeline/
|       |-- notebook.py                # RAG indexing + search pipeline for RHOAI Workbench
|       |-- requirements.txt           # Python dependencies (psycopg2, sentence-transformers, numpy)
|       +-- README.md                  # RAG pipeline documentation
|-- reports/
|   |-- coexistence-check.txt          # RHOAI coexistence check results (6/6 PASS)
|   |-- sync-results.json              # E2E sync job results (72 rows, 13592 bytes)
|   |-- certification-results.json     # Preflight and chart-verifier results
|   +-- validation-report.md           # Full validation report
+-- docs/
    +-- deployment-guide.md            # Extended deployment documentation
```

---

## Validation Environment

| Component | Version / Detail |
|-----------|-----------------|
| OpenShift | 4.21.16 |
| Kubernetes | 1.34.7 |
| Red Hat OpenShift AI | 3.4.1 |
| Airbyte | 2.1.1 (Helm chart `airbyte-v2/airbyte`) |
| Helm | 3.x |
| openshift-preflight | 1.21.0 |
| chart-verifier | 1.16.0 |
| Cluster | ai-dev02.kni.syseng.devcluster.openshift.com |
| Cloud provider | AWS |
| Nodes | 22 total (7 schedulable workers + 15 infra/control) |
| Namespace | airbyte-validation |
| Route | airbyte-server-airbyte-validation.apps.ai-dev02.kni.syseng.devcluster.openshift.com |
| Test source | PostgreSQL 16 (`registry.redhat.io/rhel9/postgresql-16`) |

Helm deploy command:

```bash
helm upgrade --install airbyte airbyte-v2/airbyte \
  --namespace airbyte-validation \
  --values openshift-values.yaml \
  --version 2.1.1 \
  --wait \
  --atomic
```
