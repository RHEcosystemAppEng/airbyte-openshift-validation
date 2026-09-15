# Live Demo Runbook — Airbyte on OpenShift AI

Estimated duration: 15-20 minutes. Assumes the cluster is accessible and Airbyte is deployed in `airbyte-validation` namespace.

**Pre-meeting checklist:**
- [ ] `oc login` to ai-dev02 cluster
- [ ] Open `demo/dashboard.html` in browser (backup if cluster is down)
- [ ] Terminal ready with `oc` and `curl`
- [ ] Airbyte UI tab open: `https://airbyte-server-airbyte-validation.apps.ai-dev02.kni.syseng.devcluster.openshift.com`

---

## 1. Open with the Dashboard (2 min)

Open `demo/dashboard.html` in the browser. Walk through:

**Talking point:** "We validated Airbyte 2.1.1 on OpenShift 4.21 running alongside RHOAI 3.4.1. The verdict is a conditional pass — Airbyte deploys and runs correctly under OpenShift's strictest security policy, but has one high-severity bug and isn't yet Red Hat certified."

Point to:
- The 4 green PASS cards (deployment, SCC, coexistence, E2E sync)
- The 2 red FAIL cards (certification checks — expected pre-certification)
- The amber CONDITIONAL PASS badge

---

## 2. Show Pods Running Under restricted-v2 (3 min)

Switch to terminal:

```bash
# Show all Airbyte pods healthy
oc get pods -n airbyte-validation

# Show SCC compliance — every pod runs under restricted-v2
oc get pods -n airbyte-validation -o json | \
  jq -r '.items[] | "\(.metadata.name)  SCC=\(.metadata.annotations["openshift.io/scc"])  Phase=\(.status.phase)"'
```

**Talking point:** "Every pod runs under restricted-v2 — the strictest default SCC. No custom SCCs, no privilege escalation, no root containers. Airbyte runs as UID 1000 which matches our namespace constraint. This is notable because many third-party apps require custom SCCs on OpenShift."

---

## 3. Show RHOAI Coexistence (2 min)

```bash
# Show RHOAI pods are healthy alongside Airbyte
oc get pods -n redhat-ods-applications --no-headers | wc -l
oc get pods -n redhat-ods-applications | head -10

# Show DataScienceCluster components
oc get datasciencecluster -o jsonpath='{range .items[0].spec.components.*}{@.managementState}{"\n"}{end}' 2>/dev/null
```

**Talking point:** "22 RHOAI pods running alongside Airbyte with zero conflicts. No CRD collisions, no resource contention — Airbyte uses standard Kubernetes resources and stays in its own namespace."

---

## 4. Show the Airbyte UI (3 min)

Switch to the Airbyte UI browser tab.

Navigate to:
1. **Connections page** — show the "OpenShift Validation Sync" connection
2. **Source** — show the PostgreSQL source configuration
3. **Destination** — show the PostgreSQL destination (airbyte_output schema)
4. **Sync history** — show job 6 completed successfully

**Talking point:** "We created the source, destination, and connection entirely via Airbyte's public API — no manual UI interaction needed. This is important for GitOps and automation workflows on OpenShift."

---

## 5. Verify Synced Data (2 min)

```bash
# Show data landed in the destination schema
oc exec deploy/postgresql -n airbyte-validation -- \
  psql -U airbyte_test -d sample_data -c "
    SELECT 'customers' as stream, count(*) FROM airbyte_output.customers
    UNION ALL
    SELECT 'documents', count(*) FROM airbyte_output.documents
    UNION ALL
    SELECT 'metadata', count(*) FROM airbyte_output.metadata;
  "
```

Expected output: customers=10, documents=17, metadata=45 (72 total).

**Talking point:** "72 rows across 3 tables — documents, metadata, and customers — synced from the source PostgreSQL to the destination in under 4 minutes. This data is now available to any RHOAI workbench or pipeline running in the cluster."

---

## 6. Demonstrate the Blocker (3 min)

This is the most important finding. Scroll to the "Blockers" section on the dashboard.

**Talking point:** "The one blocker we found: Airbyte's replication orchestrator hardcodes container resource requests at 2 CPU per container — 4 CPU total for a sync job — regardless of what you configure in the Helm values."

Show the evidence:

```bash
# The Helm values set 250m CPU
grep -A3 'replication:' ../helm/openshift-values.yaml | head -6

# The ConfigMap correctly has 250m
oc get configmap airbyte-airbyte-env -n airbyte-validation -o json | \
  jq -r '.data | to_entries[] | select(.key | test("REPLICATION.*CPU")) | "\(.key)=\(.value)"'
```

**Talking point:** "The Helm chart correctly renders the values into the ConfigMap, and the workload-launcher reads them correctly. But the replication orchestrator ignores its own environment variables and hardcodes 2 CPU. On a shared OpenShift cluster where worker nodes are typically 90%+ allocated, the sync pods can't schedule. We had to manually patch the pod resources to get the sync to complete."

---

## 7. Integration with RHOAI (2 min)

Scroll to the Architecture section on the dashboard.

**Talking point:** "The integration pattern is straightforward: Airbyte ingests data from external sources into a shared PostgreSQL instance. RHOAI workbenches connect to that same database and can immediately use the data for model training, RAG pipelines, or analytics. We built an example notebook that reads the Airbyte-synced documents, generates embeddings with sentence-transformers, and runs similarity search — a complete RAG pipeline."

Point to `examples/rag-pipeline/` in the repo structure.

---

## 8. Certification Status (2 min)

Scroll to the Certification Status section on the dashboard.

**Talking point:** "On the certification side, the image passes the critical RunAsNonRoot check but fails three checks that require Airbyte to invest in Red Hat certification: UBI base image, /licenses directory, and required OCI labels. The Helm chart has similar gaps — no values schema, no kubeVersion, uncertified images. These are all standard pre-certification gaps, not fundamental incompatibilities. The remediation steps are documented in detail."

---

## 9. Wrap Up (1 min)

Return to the dashboard header.

**Talking point:** "Bottom line: Airbyte works on OpenShift. It deploys under the strictest security context, coexists with RHOAI without issues, and successfully syncs data end-to-end. The one blocker — hardcoded CPU requests — has a workaround and needs an upstream fix. Certification is achievable but requires Airbyte to invest in UBI rebasing and image labeling. All findings, workarounds, and remediation steps are documented in the repo we're publishing today."

---

## Fallback: If the Cluster is Down

If you can't connect to ai-dev02:

1. Use the dashboard HTML (`demo/dashboard.html`) as the primary visual
2. Reference the validation report (`reports/validation-report.md`) for detailed evidence
3. Show the sync results JSON (`reports/sync-results.json`) for sync proof
4. Show the coexistence report (`reports/coexistence-check.txt`) for RHOAI health evidence

All evidence was captured at validation time and is available offline.
