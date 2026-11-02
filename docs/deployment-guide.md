# Deploying Airbyte on OpenShift

Reference guide for deploying Airbyte 2.1.1 (Helm V2) on OpenShift 4.14+ with restricted-v2 SCC compliance. Validated on OpenShift 4.21.16 alongside Red Hat OpenShift AI 3.4.1.

---

## Prerequisites

| Requirement | Detail |
|-------------|--------|
| OpenShift | 4.14+ (tested on 4.21.16) |
| Helm | 3.x |
| oc CLI | Logged in with cluster-admin |
| Storage | Default StorageClass provisioning RWO PVCs |

Verify access:

```bash
oc whoami
oc auth can-i create namespaces --all-namespaces
helm version --short
```

---

## 1. Create and Configure the Namespace

OpenShift requires a two-step namespace creation. Creating the namespace first lets OpenShift auto-populate the MCS security annotation; overriding UID/GID annotations afterward ensures Airbyte pods run as UID 1000.

```bash
NAMESPACE="airbyte-validation"

oc new-project "${NAMESPACE}" \
  --display-name="Airbyte" \
  --description="Airbyte data integration platform"

oc annotate namespace "${NAMESPACE}" \
  openshift.io/sa.scc.uid-range="1000/1" \
  openshift.io/sa.scc.supplemental-groups="1000/1" \
  --overwrite
```

Do **not** apply a namespace manifest with these annotations directly via `oc apply` -- it prevents OpenShift from auto-populating `openshift.io/sa.scc.mcs`, which causes pod scheduling failures.

---

## 2. Deploy Airbyte with Helm

Add the Helm repo and install using the OpenShift values overlay:

```bash
helm repo add airbyte-v2 https://airbytehq.github.io/charts
helm repo update airbyte-v2

helm install airbyte airbyte-v2/airbyte \
  --namespace "${NAMESPACE}" \
  --values openshift-values.yaml \
  --version 2.1.1 \
  --wait --atomic --timeout 10m
```

### Key Values in openshift-values.yaml

The overlay (`helm/openshift-values.yaml`) configures Airbyte for OpenShift restricted-v2 SCC compliance. Key settings:

| Setting | Value | Purpose |
|---------|-------|---------|
| `global.edition` | `community` | Open-source edition |
| `global.auth.enabled` | `false` | Disable auth (enable in production) |
| `global.workloads.resources.useConnectorResourceDefaults` | `false` | Override default connector resource requests (see Known Issues) |
| `temporalUi.enabled` | `false` | Temporal UI requires root; incompatible with restricted-v2 |
| `webapp.enabled` | `false` | V2 serves UI from the server component |
| `ingress.enabled` | `false` | Use OpenShift Routes instead |

Every pod specifies restricted-v2-compliant security context:

```yaml
containerSecurityContext:
  allowPrivilegeEscalation: false
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  readOnlyRootFilesystem: false
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

---

## 3. Post-Deployment

### Create an OpenShift Route

Expose the Airbyte UI/API via an OpenShift Route with edge TLS:

```yaml
# manifests/route.yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: airbyte-server
  namespace: airbyte-validation  # match your namespace
spec:
  to:
    kind: Service
    name: airbyte-airbyte-server-svc
    weight: 100
  port:
    targetPort: 8001
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

```bash
oc apply -f manifests/route.yaml
ROUTE=$(oc get route airbyte-server -n "${NAMESPACE}" -o jsonpath='{.spec.host}')
echo "Airbyte UI: https://${ROUTE}"
```

### Verify Pods

All platform pods should be Running (bootloader will show Completed):

```bash
oc get pods -n "${NAMESPACE}"
```

Expected platform components (9 Airbyte pods plus external object storage):

| Pod | Expected Status |
|-----|-----------------|
| airbyte-server | Running |
| airbyte-worker | Running |
| airbyte-workload-launcher | Running |
| airbyte-workload-api-server | Running |
| airbyte-temporal | Running |
| airbyte-cron | Running |
| airbyte-manifest-server | Running |
| airbyte-db-0 | Running |
| External S3-compatible object storage | Configured through `global.storage` |
| airbyte-bootloader | Completed |

Verify all pods run under restricted-v2 SCC:

```bash
oc get pods -n "${NAMESPACE}" -o json | \
  jq -r '.items[] | "\(.metadata.name): \(.metadata.annotations["openshift.io/scc"])"'
```

### API Access

Airbyte V2 exposes the Public API at `/api/public/v1/`. The internal `/api/v1/` endpoint returns 404 in V2.

```bash
curl -s "https://${ROUTE}/api/public/v1/health" | jq .
```

### RAG connector configuration

The Phase 1 PostgreSQL validation remains in
[`scripts/04-configure-airbyte.sh`](../scripts/04-configure-airbyte.sh). Set up
the RAG scenario separately with
[`scripts/05-configure-rag-connectors.sh`](../scripts/05-configure-rag-connectors.sh).
It creates two Google Drive sources, an S3 source, a PostgreSQL source, an
S3-compatible landing destination, and a PostgreSQL landing destination.

Connector JSON files are deliberately kept outside Git because they contain
credentials. Start with the redacted templates in
[`examples/airbyte/rag-connectors/`](../examples/airbyte/rag-connectors/) and
follow that directory's README. Connections are created as manual connections;
validate each connector before triggering a sync.

---

## 4. Known Issues and Workarounds

### Replication Pod Resource Requests (HIGH severity)

**Issue:** The Airbyte replication orchestrator hardcodes container resource requests at 2 CPU / 2 Gi per container, ignoring `global.workloads.resources` Helm values. Total request per replication pod: 4 CPU. This exceeds available capacity on most OpenShift worker nodes.

**Symptom:** Replication pods stuck in `Pending` with `Insufficient cpu` scheduler errors.

**Workaround:** After triggering a sync, if the replication pod is Pending, patch its resources:

```bash
# Export the pending pod
oc get pod <replication-pod-name> -n "${NAMESPACE}" -o json > /tmp/rep-pod.json

# Reduce resource requests
jq '
  .spec.initContainers[].resources = {"requests":{"cpu":"250m","memory":"512Mi"},"limits":{"cpu":"500m","memory":"1Gi"}} |
  .spec.containers[].resources = {"requests":{"cpu":"250m","memory":"512Mi"},"limits":{"cpu":"500m","memory":"1Gi"}} |
  del(.status, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp) |
  .metadata = {name: .metadata.name, namespace: .metadata.namespace, labels: .metadata.labels}
' /tmp/rep-pod.json > /tmp/rep-pod-fixed.json

# Delete and recreate
oc delete pod <replication-pod-name> -n "${NAMESPACE}" --force --grace-period=0
oc apply -f /tmp/rep-pod-fixed.json
```

Give the init container at least 512Mi memory -- the JVM initialization requires it.

### Temporal UI

The upstream Temporal UI image runs as root (`runAsUser: 0`) and is incompatible with OpenShift restricted-v2 SCC. Keep `temporalUi.enabled: false` unless you grant a custom SCC.

---

## 5. Production Considerations

### External Database

Replace the bundled PostgreSQL with an external instance for durability:

```yaml
global:
  database:
    type: external
    host: your-db-host
    port: 5432
    database: airbyte
    secretName: airbyte-db-credentials  # Secret with USERNAME and PASSWORD keys
postgresql:
  enabled: false
```

### Object Storage

Replace bundled MinIO with S3-compatible storage (AWS S3, OpenShift Data Foundation, etc.):

```yaml
global:
  storage:
    type: s3
    secretName: airbyte-config-secrets
    bucket:
      log: airbyte-rag
      state: airbyte-rag
      workloadOutput: airbyte-rag
    s3:
      endpoint: ""         # set for ODF or another S3-compatible service
      region: ""
      authenticationType: credentials
      accessKeyIdSecretKey: s3-access-key-id
      secretAccessKeySecretKey: s3-secret-access-key
minio:
  enabled: false
```

Create `airbyte-config-secrets` before installing the chart. Do not put S3
credentials in this values file. The RAG manifests use a separate
`milvus-s3-config` Secret for Milvus's object-storage configuration.

### Authentication

Enable authentication for production deployments:

```yaml
global:
  auth:
    enabled: true
```

This enables Airbyte's built-in auth. For SSO, enable the Keycloak components (requires addressing restricted-v2 compatibility).

### Resource Sizing

The validation overlay uses minimal resource requests suitable for testing. For production workloads, increase the server, worker, and workload-launcher resources based on connector count and sync volume:

| Component | Test | Production (suggested) |
|-----------|------|----------------------|
| server | 250m / 512Mi | 1 CPU / 2Gi |
| worker | 250m / 512Mi | 1 CPU / 2Gi |
| workload-launcher | 250m / 512Mi | 500m / 1Gi |
| temporal | 250m / 512Mi | 500m / 1Gi |

### Replicas

Scale server and worker for high availability:

```yaml
server:
  replicaCount: 2
worker:
  replicaCount: 2
```

---

## Appendix: File Reference

| File | Purpose |
|------|---------|
| `helm/openshift-values.yaml` | Helm values overlay for OpenShift restricted-v2 compliance |
| `manifests/namespace.yaml` | Namespace manifest (reference only -- use two-step creation) |
| `manifests/route.yaml` | OpenShift Route for Airbyte UI/API |
| `scripts/01-deploy-airbyte.sh` | Automated deployment script (idempotent) |
| `scripts/00-prereqs.sh` | Prerequisite validation script |
| `scripts/04-configure-airbyte.sh` | Phase 1 PostgreSQL-to-PostgreSQL validation |
| `scripts/05-configure-rag-connectors.sh` | RAG scenario source/destination/connection setup |
| `examples/airbyte/rag-connectors/` | Redacted connector JSON templates and setup instructions |
