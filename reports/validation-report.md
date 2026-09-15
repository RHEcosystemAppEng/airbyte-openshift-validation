# Airbyte on OpenShift AI — Partner Validation Report

**Date:** 2026-08-27
**Cluster:** ai-dev02.kni.syseng.devcluster.openshift.com
**OpenShift Version:** 4.21.16 (Kubernetes 1.34.7)
**RHOAI Version:** 3.4.1
**Airbyte Version:** 2.1.1 (Helm chart airbyte-v2/airbyte)
**Namespace:** airbyte-validation

---

## Executive Summary

Airbyte 2.1.1 deploys and operates on OpenShift 4.21 alongside Red Hat OpenShift AI 3.4.1 with **one critical blocker** requiring a workaround. All core platform pods run under the `restricted-v2` SCC without requiring elevated privileges. End-to-end data ingestion was validated with 72 rows synced across 3 tables from PostgreSQL source to PostgreSQL destination.

| Category | Result |
|----------|--------|
| Deployment on OpenShift | **PASS** (with namespace annotation workaround) |
| restricted-v2 SCC Compliance | **PASS** — all pods run under restricted-v2 |
| RHOAI Coexistence | **PASS** — 6/6 checks passed, zero conflicts |
| E2E Data Ingestion | **PASS** (with pod resource workaround) |
| Preflight (container image) | **FAIL** — 7 pass / 3 fail (pre-certification gaps) |
| Chart-verifier (Helm chart) | **FAIL** — 8 pass / 5 fail (pre-certification gaps) |

**Overall Verdict: CONDITIONAL PASS** — Airbyte functions correctly on OpenShift with RHOAI but has one high-severity bug (hardcoded container resources) and is not yet Red Hat certified.

---

## 1. Deployment Validation

### 1.1 Helm Deployment

Airbyte was deployed using:
```
helm upgrade --install airbyte airbyte-v2/airbyte \
  --namespace airbyte-validation \
  --values openshift-values.yaml \
  --version 2.1.1 --wait --atomic
```

**Result: PASS** — All 10 platform pods reached Running/Completed state.

| Pod | Status | SCC |
|-----|--------|-----|
| airbyte-server | Running | restricted-v2 |
| airbyte-worker | Running | restricted-v2 |
| airbyte-workload-launcher | Running | restricted-v2 |
| airbyte-workload-api-server | Running | restricted-v2 |
| airbyte-temporal | Running | restricted-v2 |
| airbyte-cron | Running | restricted-v2 |
| airbyte-manifest-server | Running | restricted-v2 |
| airbyte-db-0 | Running | restricted-v2 |
| airbyte-minio-0 | Running | restricted-v2 |
| airbyte-bootloader | Completed | restricted-v2 |

### 1.2 Namespace Configuration

OpenShift requires a two-step namespace creation to ensure proper MCS annotation:

1. `oc new-project airbyte-validation` — creates namespace with auto-populated MCS annotation
2. `oc annotate namespace airbyte-validation openshift.io/sa.scc.uid-range="1000/1" openshift.io/sa.scc.supplemental-groups="1000/1" --overwrite`

**Finding:** Direct `oc apply` of a namespace manifest with UID annotations prevents OpenShift from auto-populating the MCS annotation, causing pod scheduling failures. This is an OpenShift behavior, not an Airbyte issue.

### 1.3 Security Context Compliance

All Airbyte pods comply with OpenShift `restricted-v2` SCC:
- `runAsNonRoot: true`
- `runAsUser: 1000`, `runAsGroup: 1000`
- `allowPrivilegeEscalation: false`
- `capabilities.drop: ["ALL"]`
- `seccompProfile.type: RuntimeDefault`

**Result: PASS** — No custom SCCs or elevated privileges required.

### 1.4 Components Disabled for OpenShift

| Component | Reason |
|-----------|--------|
| `webapp` | Disabled in V2; server serves the UI |
| `temporalUi` | Requires root (runAsUser: 0); incompatible with restricted-v2 |
| `metrics` | Not needed for validation |
| `connectorRolloutWorker` | Not needed for validation |
| `featureflagServer` | Not needed for validation |
| `keycloak` | Enterprise-only SSO; not applicable to community edition |

---

## 2. RHOAI Coexistence

**Result: PASS — 6/6 checks passed**

| Check | Result |
|-------|--------|
| RHOAI Pod Health | PASS — 22 pods healthy in redhat-ods-applications |
| DataScienceCluster Components | PASS — all managed components unchanged |
| Warning Events | PASS — no Airbyte-related warnings |
| Airbyte Pod Health | PASS — all pods healthy |
| Resource Audit | PASS — no contention (Airbyte: ~205m CPU / ~2.2 GiB) |
| CRD Conflict Check | PASS — Airbyte uses no CRDs |

RHOAI components verified healthy alongside Airbyte:
- AI Pipelines, Dashboard, KServe, Ray, Feast, Llama Stack, MLflow, Model Registry, TrustyAI, Workbenches, Trainer

---

## 3. End-to-End Data Ingestion

### 3.1 Test Setup

- **Source:** PostgreSQL 16 (registry.redhat.io/rhel9/postgresql-16) deployed in airbyte-validation namespace
- **Seed Data:** 72 rows across 3 tables (17 documents, 45 metadata entries, 10 customers)
- **Destination:** Same PostgreSQL instance, `airbyte_output` schema
- **Connection:** Created via Airbyte Public API (`/api/public/v1/`)

### 3.2 Sync Results

| Metric | Value |
|--------|-------|
| Job ID | 6 |
| Status | **succeeded** |
| Rows Synced | 72 |
| Bytes Synced | 13,592 |
| Duration | 3m 13s |
| Streams | customers (10), documents (17), metadata (45) |

**Result: PASS** — All 72 rows verified in destination `airbyte_output` schema.

### 3.3 Critical Blocker: Hardcoded Container Resources

**Severity: HIGH**
**Component:** Replication orchestrator / workload-launcher

The Airbyte replication orchestrator hardcodes container resource requests at **2 CPU / 2 Gi** per container (init, orchestrator, source, destination) regardless of Helm values configuration.

**Evidence:**
- `global.workloads.resources.useConnectorResourceDefaults: false` is set in Helm values
- `global.workloads.resources.replication.cpu.request: "250m"` is set
- ConfigMap `airbyte-airbyte-env` correctly contains `REPLICATION_ORCHESTRATOR_CPU_REQUEST=250m`
- Workload-launcher pod env vars correctly read `250m`
- **Despite all of this**, replication pods launch with 2 CPU / 2 Gi per container (4 CPU total request)
- This exceeds available capacity on typical OpenShift worker nodes (90%+ CPU allocated)

**Impact:** Replication pods fail to schedule (`Insufficient cpu`) on resource-constrained clusters, which is the norm for shared OpenShift environments.

**Workaround Applied:** Manually exported pending pod spec, modified resource requests via `jq` to 250m CPU / 512Mi memory, deleted and recreated the pod. Pod scheduled and sync completed successfully.

**Recommendation for Airbyte:** Fix the replication orchestrator to honor `REPLICATION_ORCHESTRATOR_CPU_REQUEST` and related env vars. The workload-launcher correctly reads these values but the replication orchestrator code path ignores them.

---

## 4. Certification Checks

### 4.1 Preflight (Container Image)

**Tool:** openshift-preflight 1.21.0
**Image:** docker.io/airbyte/server:2.1.1
**Overall: FAILED** (7 pass / 3 fail)

| Check | Result | Notes |
|-------|--------|-------|
| HasUniqueTag | PASS | Tag 2.1.1 (not latest) |
| LayerCountAcceptable | PASS | Under 40 layers |
| HasNoProhibitedPackages | PASS | No RHEL kernel packages |
| HasNoProhibitedLabels | PASS | No Red Hat trademark violations |
| RunAsNonRoot | **PASS** | Runs as airbyte:airbyte |
| HasModifiedFiles | PASS | No modified RPM files (warn on ca-trust) |
| HasProhibitedContainerName | PASS | No trademark violations |
| HasLicense | FAIL | No `/licenses` directory |
| HasRequiredLabel | FAIL | Missing: name, vendor, version, release, summary, description, maintainer |
| BasedOnUbi | FAIL | Not based on UBI/RHHI |

**Key Positive:** `RunAsNonRoot` passes — critical for OpenShift restricted-v2 SCC.

**Remediation for Certification:**
1. Rebase images on UBI9
2. Add `/licenses` directory with licensing files
3. Add required OCI labels (name, vendor, version, release, summary, description, maintainer)

### 4.2 Chart-Verifier (Helm Chart)

**Tool:** chart-verifier 1.16.0
**Chart:** airbyte-2.1.1.tgz
**Profile:** partner v1.3
**Overall: FAILED** (8 pass / 5 fail / 1 skipped)

| Check | Result | Notes |
|-------|--------|-------|
| contains-test | PASS | Test files present |
| has-notes | PASS | NOTES.txt present |
| not-contains-crds | PASS | No CRDs |
| has-readme | PASS | README present |
| helm-lint | PASS | Lint clean |
| contains-values | PASS | values.yaml present |
| is-helm-v3 | PASS | API version v2 |
| not-contain-csi-objects | PASS | No CSI objects |
| contains-values-schema | FAIL | No values.schema.json |
| has-kubeversion | FAIL | kubeVersion not in Chart.yaml |
| images-are-certified | FAIL | 0/11 images Red Hat certified |
| chart-testing | FAIL | Requires live cluster (ran in podman) |
| required-annotations-present | FAIL | Missing charts.openshift.io/name |
| signature-is-valid | SKIPPED | Chart unsigned |

**Remediation for Certification:**
1. Add `values.schema.json` for Helm values validation
2. Set `kubeVersion` constraint in Chart.yaml
3. Certify container images through Red Hat Connect
4. Add `charts.openshift.io/name` annotation to Chart.yaml

---

## 5. Findings Summary

### Blockers

| # | Severity | Finding | Status |
|---|----------|---------|--------|
| 1 | HIGH | Replication orchestrator ignores resource env var overrides, hardcodes 2 CPU / 2 Gi per container | Workaround applied; upstream fix needed |

### Observations

| # | Category | Finding |
|---|----------|---------|
| 2 | Deployment | Namespace must use two-step creation (oc new-project + annotate) for MCS annotation |
| 3 | API | Airbyte V2 uses `/api/public/v1/` (not `/api/v1/`); internal API returns 404 |
| 4 | Security | `temporalUi` requires root — must remain disabled on OpenShift restricted-v2 |
| 5 | Certification | Container images not based on UBI, missing required labels and /licenses |
| 6 | Certification | Helm chart missing values.schema.json, kubeVersion, and OpenShift annotations |

### Positives

| # | Finding |
|---|---------|
| 1 | All platform pods run under restricted-v2 SCC — no custom SCCs needed |
| 2 | Airbyte runs as UID 1000 — compatible with OpenShift namespace UID constraints |
| 3 | Zero impact on RHOAI components — complete isolation |
| 4 | Low resource footprint (~205m CPU / ~2.2 GiB for platform pods) |
| 5 | Helm chart passes lint, has tests, README, and NOTES.txt |
| 6 | RunAsNonRoot preflight check passes |

---

## 6. Remediation Guide

This section provides concrete steps for resolving each finding. Items are grouped by owner (Airbyte upstream vs. deployer) and ordered by priority.

### 6.1 Airbyte Upstream Fixes (required for certification and production readiness)

#### Finding #1 — Replication Pod Hardcoded Resources (HIGH)

**Root cause:** The replication orchestrator builds pod specs with hardcoded resource requests (2 CPU / 2 Gi per container) instead of reading `REPLICATION_ORCHESTRATOR_CPU_REQUEST` and related env vars from the ConfigMap.

**Fix required in Airbyte source:**
1. Locate the pod-spec construction in the replication orchestrator (likely in the container-orchestrator or workload-launcher module)
2. Replace hardcoded resource values with reads from the env vars that the Helm chart already populates:
   - `REPLICATION_ORCHESTRATOR_CPU_REQUEST` / `REPLICATION_ORCHESTRATOR_CPU_LIMIT`
   - `REPLICATION_ORCHESTRATOR_MEMORY_REQUEST` / `REPLICATION_ORCHESTRATOR_MEMORY_LIMIT`
   - `JOB_MAIN_CONTAINER_CPU_REQUEST` / `JOB_MAIN_CONTAINER_CPU_LIMIT`
   - `JOB_MAIN_CONTAINER_MEMORY_REQUEST` / `JOB_MAIN_CONTAINER_MEMORY_LIMIT`
3. The workload-launcher already reads these correctly — the disconnect is downstream in the orchestrator

**Deployer workaround (until upstream fix):**
```bash
# When a replication pod is stuck in Pending with "Insufficient cpu":
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

#### Finding #5 — Container Images Not Based on UBI

**Steps for Airbyte to certify images through Red Hat Connect:**
1. Rebase all Dockerfiles on `registry.access.redhat.com/ubi9/ubi-minimal:latest` (or `ubi9/openjdk-21-runtime` for JVM services)
2. Add a `/licenses` directory containing the Apache 2.0 license text and any third-party notices
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
4. Submit images to Red Hat Connect portal for certification scanning
5. Publish certified images to `registry.connect.redhat.com`

#### Finding #6 — Helm Chart Certification Gaps

**Steps for Airbyte to pass chart-verifier:**
1. **values.schema.json** — Generate a JSON Schema from the current `values.yaml` (tools like `helm-schema-gen` can bootstrap this) and include it in the chart
2. **kubeVersion** — Add to `Chart.yaml`:
   ```yaml
   kubeVersion: ">=1.26.0-0"
   ```
3. **OpenShift annotation** — Add to `Chart.yaml`:
   ```yaml
   annotations:
     charts.openshift.io/name: airbyte
   ```
4. **Chart signing** — Sign the chart with a GPG key and publish the provenance file alongside the `.tgz`

### 6.2 Deployer-Side Configuration (required for any OpenShift deployment)

#### Finding #2 — Namespace Two-Step Creation

**Why:** OpenShift auto-populates the `openshift.io/sa.scc.mcs` annotation when a namespace is created. Applying a namespace manifest with custom UID annotations via `oc apply` prevents this auto-population, causing pods to fail SCC validation.

**Correct procedure:**
```bash
# Step 1: Create namespace (auto-populates MCS annotation)
oc new-project airbyte-validation

# Step 2: Override UID/GID annotations
oc annotate namespace airbyte-validation \
  openshift.io/sa.scc.uid-range="1000/1" \
  openshift.io/sa.scc.supplemental-groups="1000/1" \
  --overwrite
```

This is automated in `scripts/01-deploy-airbyte.sh`.

#### Finding #3 — API Version (V2 Public API)

Any automation or monitoring that calls the Airbyte API must use `/api/public/v1/` endpoints. The internal `/api/v1/` returns 404 in V2. Key endpoint mapping:

| Operation | V1 (broken) | V2 Public API |
|-----------|-------------|---------------|
| List workspaces | `POST /api/v1/workspaces/list` | `GET /api/public/v1/workspaces` |
| Create source | `POST /api/v1/sources/create` | `POST /api/public/v1/sources` |
| Create destination | `POST /api/v1/destinations/create` | `POST /api/public/v1/destinations` |
| Create connection | `POST /api/v1/connections/create` | `POST /api/public/v1/connections` |
| Trigger sync | `POST /api/v1/connections/sync` | `POST /api/public/v1/jobs` |
| Get job status | `POST /api/v1/jobs/get` | `GET /api/public/v1/jobs/{jobId}` |

#### Finding #4 — Temporal UI Disabled

`temporalUi` runs as root (`runAsUser: 0`) and is incompatible with OpenShift `restricted-v2` SCC. Keep it disabled in `openshift-values.yaml`:

```yaml
temporalUi:
  enabled: false
```

If Temporal UI access is needed for debugging, grant the `anyuid` SCC to its service account (not recommended for production).

---

## 7. Environment Details

| Component | Version / Detail |
|-----------|-----------------|
| OpenShift | 4.21.16 |
| Kubernetes | 1.34.7 |
| RHOAI | 3.4.1 |
| Airbyte | 2.1.1 (Helm chart airbyte-v2) |
| Helm | 3.x |
| Cluster | ai-dev02 (AWS, 22 nodes: 7 schedulable workers + 15 infra/control) |
| Namespace | airbyte-validation |
| Route | airbyte-server-airbyte-validation.apps.ai-dev02.kni.syseng.devcluster.openshift.com |

---

## 8. Artifacts Produced

| Artifact | Path |
|----------|------|
| OpenShift values overlay | `helm/openshift-values.yaml` |
| Namespace manifest | `manifests/namespace.yaml` |
| Route manifest | `manifests/route.yaml` |
| PostgreSQL test source | `manifests/postgresql.yaml` |
| Seed data | `data/seed.sql` |
| Deployment script | `scripts/01-deploy-airbyte.sh` |
| Coexistence report | `reports/coexistence-check.txt` |
| Sync results | `reports/sync-results.json` |
| Certification results | `reports/certification-results.json` |
| This report | `reports/validation-report.md` |
