# Known Issues, Workarounds, and Remediation Roadmap

Issues discovered during the Airbyte 2.1.1 validation on OpenShift 4.21.16 with RHOAI 3.4.1.

---

## Finding #1: Replication Pod Hardcoded Resources (HIGH)

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

**Upstream fix:** Replace hardcoded resource values in the replication orchestrator module (likely `container-orchestrator` or `workload-launcher`) with reads from these environment variables.

---

## Finding #2: Namespace MCS Annotation (MEDIUM)

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

## Finding #3: API Version Change -- V1 to Public V1 (LOW)

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

## Finding #4: Temporal UI Requires Root (LOW)

**Severity:** LOW

**Problem:** The upstream Temporal UI image hardcodes `runAsUser: 0` (root), which is incompatible with the `restricted-v2` SCC.

**Fix:** Keep `temporalUi.enabled: false` in the values overlay. If Temporal UI access is needed for debugging, grant the `anyuid` SCC to its service account (not recommended for production).

---

## Remediation Roadmap

### Airbyte Upstream Fixes

These require changes to the Airbyte codebase or build pipeline.

1. **Replication orchestrator resource bug (HIGH)** — See [Finding #1](#finding-1-replication-pod-hardcoded-resources-high) above.
2. **UBI-based container images** — Rebase all Dockerfiles on `ubi9/ubi-minimal` (or `ubi9/openjdk-21-runtime` for JVM services). Add `/licenses` directory and required OCI labels. Submit to Red Hat Connect for certification.
3. **Helm chart certification metadata** — Add `values.schema.json`, add `kubeVersion: ">=1.26.0-0"` to `Chart.yaml`, add `charts.openshift.io/name: airbyte` annotation, sign the chart with a GPG key.

### Deployer Configuration

Steps that OpenShift administrators must take when deploying Airbyte.

1. **Namespace setup** — Use the two-step creation process (see [deployment guide](deployment-guide.md)). Never apply the namespace manifest directly with UID/GID annotations.
2. **API version** — All Airbyte V2 API calls must use `/api/public/v1/` as the base path. The old `/api/v1/` returns 404.
3. **Disabled components** — Keep `temporalUi.enabled: false` unless you are willing to grant a custom SCC. Keep `webapp.enabled: false` (deprecated in V2).
4. **Production hardening:**

| Area | Validation Setting | Production Recommendation |
|------|--------------------|---------------------------|
| Authentication | `global.auth.enabled: false` | Enable with OIDC or built-in auth |
| Telemetry | `global.tracking.enabled: false` | Enable if not air-gapped |
| Database | Bundled PostgreSQL (2Gi PVC) | External managed PostgreSQL |
| Object storage | External S3-compatible store | ODF, AWS S3, or another S3-compatible service |
| Resource sizing | Minimal requests (100-250m CPU) | Scale per workload requirements |
| TLS | Edge termination at router | Consider passthrough or re-encrypt for sensitive data |
| Node selectors | Cleared (`global.topology.*: ""`) | Set to dedicated node pools |
