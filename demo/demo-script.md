# Airbyte on OpenShift AI — Live Demo Script

**Audience:** Red Hat partner engineering stakeholders
**Duration:** ~15 minutes
**Cluster:** ai-dev02.kni.syseng.devcluster.openshift.com (re-login if session expired)

---

## Pre-Demo Checklist

- [ ] Log in to OpenShift: `oc login https://api.ai-dev02.kni.syseng.devcluster.openshift.com:6443`
- [ ] Open `demo/dashboard.html` in browser (full-screen on projector)
- [ ] Open a second browser tab to Airbyte UI: `https://airbyte-server-airbyte-validation.apps.ai-dev02.kni.syseng.devcluster.openshift.com`
- [ ] Open a third tab to OpenShift console: `https://console-openshift-console.apps.ai-dev02.kni.syseng.devcluster.openshift.com`
- [ ] Terminal ready with `oc` logged in

---

## Demo Flow

### 1. Set the Context (2 min)

**Talking points:**
- This is the first of 6 data partner validations under the Red Hat data partner strategy
- Goal: can Airbyte deploy on OpenShift, coexist with RHOAI, and move data into AI workloads?
- We validated Airbyte 2.1.1 (community edition) on OCP 4.21.16 with RHOAI 3.4.1

**Show:** Dashboard header and status matrix (tab 1)

> "The overall verdict is CONDITIONAL PASS. Core functionality works — deployment, SCC compliance, coexistence, and data ingestion all pass. The conditions are pre-certification gaps that Airbyte needs to address and one resource bug we found."

---

### 2. Show Deployment on OpenShift (3 min)

**Terminal commands:**

```bash
# Show all Airbyte pods running under restricted-v2 SCC
oc get pods -n airbyte-validation -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.phase,SCC:.metadata.annotations.openshift\.io/scc'

# Show namespace UID annotations (1000/1)
oc get namespace airbyte-validation -o jsonpath='{.metadata.annotations}' | jq .

# Show RHOAI pods healthy alongside Airbyte
echo "--- RHOAI pods ---"
oc get pods -n redhat-ods-applications --no-headers | wc -l
echo "pods running"
```

**Talking points:**
- All 10 Airbyte pods run under `restricted-v2` — the strictest default SCC. No custom SCCs, no privilege escalation, no root containers.
- We run everything as UID 1000 using namespace annotations.
- 22 RHOAI pods continue running healthy — zero impact.

**Show:** OpenShift console (tab 3) — navigate to Workloads > Pods in `airbyte-validation` namespace

---

### 3. Show the Airbyte UI (2 min)

**Show:** Airbyte UI (tab 2)

Navigate to:
1. **Connections page** — show the "OpenShift Validation Sync" connection
2. **Click into the connection** — show source (PostgreSQL) and destination (PostgreSQL/airbyte_output)
3. **Job history** — show Job 6: succeeded, 72 rows, 13,592 bytes

> "We configured everything through the Airbyte Public API — source, destination, connection, and sync trigger. This is the same API customers would use for automation."

---

### 4. Show the Data Flow (3 min)

**Terminal commands:**

```bash
# Show data in the SOURCE (public schema)
oc exec deploy/postgresql -n airbyte-validation -- \
  psql -U airbyte_test -d sample_data -c \
  "SELECT schemaname, tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"

# Show data in the DESTINATION (airbyte_output schema)  
oc exec deploy/postgresql -n airbyte-validation -- \
  psql -U airbyte_test -d sample_data -c \
  "SELECT relname as tablename, n_live_tup as rows FROM pg_stat_user_tables WHERE schemaname = 'airbyte_output' AND relname NOT LIKE 'airbyte_%' ORDER BY relname;"

# Show a sample document that would feed into a RAG pipeline
oc exec deploy/postgresql -n airbyte-validation -- \
  psql -U airbyte_test -d sample_data -c \
  "SELECT id, title, source, length(content) as content_length FROM airbyte_output.documents LIMIT 5;"
```

**Talking points:**
- Source: 72 rows across 3 tables (documents, metadata, customers)
- Airbyte synced all 72 rows into the `airbyte_output` schema
- This data is now accessible to any RHOAI workbench in the cluster

**Show:** Dashboard architecture diagram and sync evidence section

---

### 5. Show the Integration Example (2 min)

**Show:** Dashboard integration section, then briefly show `examples/rag-pipeline/notebook.py` in an editor

> "We built a RAG pipeline example that shows how an RHOAI Workbench connects to the Airbyte-synced data, chunks documents, generates embeddings with sentence-transformers, and runs similarity search. This is the pattern for feeding Airbyte data into AI workloads."

**Talking points:**
- Airbyte handles the data ingestion layer (extract + load)
- RHOAI handles the AI layer (transform, embed, serve)
- PostgreSQL is the shared data layer — both systems access it via in-cluster services
- This pattern works with any Airbyte connector (Salesforce, Snowflake, APIs, etc.)

---

### 6. Show the Blocker (2 min)

**Show:** Dashboard "Blockers" card

> "We found one high-severity bug. Airbyte's replication orchestrator hardcodes 2 CPU per container in the pod spec, regardless of what you configure in Helm values. On a typical shared OpenShift cluster where nodes are 90%+ committed, the replication pod can't schedule."

**Terminal — prove the bug in two commands:**

```bash
# 1. Show what Helm TOLD Airbyte to use (system-generated ConfigMap)
oc get configmap airbyte-airbyte-env -n airbyte-validation -o json | \
  jq '.data | with_entries(select(.key | contains("CHECK_JOB") or contains("REPLICATION_ORCHESTRATOR")))'

# 2. Show what Airbyte ACTUALLY requested (live pod spec)
#    Replace the pod name with whatever check/replication pod exists:
oc get pods -n airbyte-validation --no-headers | grep -E 'check|replication'
oc get pod $(oc get pods -n airbyte-validation --no-headers -o custom-columns=':metadata.name' | grep -E 'check|replication' | head -1) \
  -n airbyte-validation \
  -o jsonpath='{range .spec.containers[*]}{"  "}{.name}{": "}{.resources.requests.cpu}{" CPU / "}{.resources.requests.memory}{" memory\n"}{end}'
```

> "The first command shows the ConfigMap — this is what Helm told Airbyte to use: 250m CPU. The second command shows what Airbyte actually put in the pod spec. These two values don't match. Airbyte ignores its own configuration."

> "We proved this is the root cause by manually patching a replication pod to 250m — it scheduled immediately and the sync completed in 3 minutes, 72 rows. That's job 6 in the Airbyte UI."

---

### 7. Certification Status and Next Steps (2 min)

**Show:** Dashboard certification gaps section

**Talking points:**
- Preflight: 7/10 pass. Key positive: RunAsNonRoot passes. Failures are all pre-certification (no UBI base, missing labels, no /licenses dir).
- Chart-verifier: 8/14 pass. Failures: no values.schema.json, no kubeVersion, images not in Red Hat catalog.
- None of these are functional blockers — they're checklist items for formal Red Hat certification.

> "The remediation roadmap has two tracks: what Airbyte needs to do upstream (fix the CPU bug, rebase on UBI, add labels) and what deployers need to know (namespace setup, API version, disabled components). It's all documented in the repo."

---

## If Asked

**Q: Can this run in production?**
A: The platform pods are production-ready on OpenShift. The blocker is the replication resource bug — until Airbyte fixes it, syncs on resource-constrained clusters need the manual pod-fix workaround. We recommend filing this upstream before production deployment.

**Q: What about other connectors?**
A: We validated with the PostgreSQL source and destination connectors. The deployment and SCC compliance apply to all connectors — they all run as the same UID under restricted-v2. Resource behavior may vary per connector.

**Q: What's the resource overhead?**
A: Airbyte platform pods: ~205m CPU, ~2.2 GiB memory. Minimal footprint. The issue is only with replication job pods during active syncs.

**Q: What about air-gapped / disconnected clusters?**
A: The Helm chart supports custom image registries (`global.image.registry`). Images would need to be mirrored. MinIO provides local object storage. No external dependencies at runtime.

**Q: Timeline for the other 5 partners?**
A: This validation framework (scripts, values overlay, report structure) is reusable. The next partner validation should take significantly less time since the methodology is established.
