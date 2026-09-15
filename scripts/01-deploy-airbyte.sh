#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 01-deploy-airbyte.sh
#
# Deploy Airbyte to an OpenShift cluster using Helm.
# Idempotent — safe to re-run at any time.
#
# Assumes execution from the scripts/ directory.
###############################################################################

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
NAMESPACE="airbyte-validation"
HELM_RELEASE="airbyte"
CHART_REPO="airbyte-v2"
CHART_URL="https://airbytehq.github.io/charts"
VALUES_FILE="../helm/openshift-values.yaml"
POD_READY_TIMEOUT="10m"

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail()  { printf "${RED}[FAIL]${NC}  %s\n" "$*"; exit 1; }

banner() {
  printf "\n${BOLD}========================================${NC}\n"
  printf "${BOLD} Airbyte on OpenShift — Deployment${NC}\n"
  printf "${BOLD}========================================${NC}\n\n"
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
check_prerequisites() {
  info "Checking prerequisites..."

  # oc CLI available and logged in
  if ! command -v oc &>/dev/null; then
    fail "oc CLI not found. Install the OpenShift CLI first."
  fi

  if ! oc whoami &>/dev/null; then
    fail "Not logged in to an OpenShift cluster. Run 'oc login' first."
  fi
  ok "Logged in as $(oc whoami) on $(oc whoami --show-server)"

  # helm CLI available
  if ! command -v helm &>/dev/null; then
    fail "helm CLI not found. Install Helm 3 first."
  fi
  ok "Helm $(helm version --short) available"

  # cluster-admin check — attempt to list cluster-role bindings
  if ! oc auth can-i create namespaces --all-namespaces &>/dev/null; then
    fail "Current user lacks cluster-admin privileges. Elevate permissions before running this script."
  fi
  ok "Cluster-admin access confirmed"

  # Values file exists
  if [[ ! -f "${VALUES_FILE}" ]]; then
    fail "Helm values file not found at ${VALUES_FILE}. Ensure the file exists relative to scripts/."
  fi
  ok "Values file found: ${VALUES_FILE}"
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
create_namespace() {
  info "Creating namespace '${NAMESPACE}'..."

  if oc get namespace "${NAMESPACE}" &>/dev/null; then
    info "Namespace '${NAMESPACE}' already exists — verifying annotations..."
  else
    oc new-project "${NAMESPACE}" \
      --display-name="Airbyte Validation" \
      --description="Airbyte on OpenShift AI partner validation" 2>/dev/null \
      || oc create namespace "${NAMESPACE}"
  fi

  # Override UID/GID annotations (must happen after creation so MCS auto-populates)
  oc annotate namespace "${NAMESPACE}" \
    openshift.io/sa.scc.uid-range="1000/1" \
    openshift.io/sa.scc.supplemental-groups="1000/1" \
    --overwrite

  oc label namespace "${NAMESPACE}" \
    app.kubernetes.io/part-of=airbyte-validation \
    purpose=partner-validation \
    --overwrite

  ok "Namespace '${NAMESPACE}' ready with UID/GID 1000 annotations"
}

# ---------------------------------------------------------------------------
# Helm repo
# ---------------------------------------------------------------------------
add_helm_repo() {
  info "Ensuring Helm repo '${CHART_REPO}' is registered..."
  if helm repo list 2>/dev/null | grep -q "^${CHART_REPO}[[:space:]]"; then
    info "Helm repo '${CHART_REPO}' already present — updating..."
    helm repo update "${CHART_REPO}"
  else
    helm repo add "${CHART_REPO}" "${CHART_URL}"
    info "Helm repo '${CHART_REPO}' added"
  fi
  ok "Helm repo ready"
}

# ---------------------------------------------------------------------------
# Deploy Airbyte
# ---------------------------------------------------------------------------
deploy_airbyte() {
  info "Deploying Airbyte (helm upgrade --install)..."
  helm upgrade --install "${HELM_RELEASE}" "${CHART_REPO}/airbyte" \
    --namespace "${NAMESPACE}" \
    --values "${VALUES_FILE}" \
    --timeout "${POD_READY_TIMEOUT}" \
    --wait \
    --atomic
  ok "Helm release '${HELM_RELEASE}' deployed in namespace '${NAMESPACE}'"
}

# ---------------------------------------------------------------------------
# Wait for pods
# ---------------------------------------------------------------------------
wait_for_pods() {
  info "Waiting for all pods in '${NAMESPACE}' to become ready (timeout: ${POD_READY_TIMEOUT})..."

  # Wait for at least one pod to exist before waiting on readiness
  local retries=0
  while [[ $(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l) -eq 0 ]]; do
    retries=$((retries + 1))
    if [[ ${retries} -ge 30 ]]; then
      fail "No pods appeared in namespace '${NAMESPACE}' after 30 seconds"
    fi
    sleep 1
  done

  if ! oc wait --for=condition=Ready pods \
    --all \
    --namespace "${NAMESPACE}" \
    --timeout="${POD_READY_TIMEOUT}"; then
    warn "Some pods did not reach Ready state within ${POD_READY_TIMEOUT}"
    return 1
  fi
  ok "All pods are ready"
}

# ---------------------------------------------------------------------------
# Apply Route
# ---------------------------------------------------------------------------
apply_route() {
  info "Applying Route manifest..."
  if [[ -f ../manifests/route.yaml ]]; then
    oc apply -f ../manifests/route.yaml -n "${NAMESPACE}"
    ok "Route applied"
  else
    warn "Route manifest not found at ../manifests/route.yaml — skipping"
  fi
}

# ---------------------------------------------------------------------------
# Status summary
# ---------------------------------------------------------------------------
print_summary() {
  printf "\n${BOLD}========================================${NC}\n"
  printf "${BOLD} Deployment Summary${NC}\n"
  printf "${BOLD}========================================${NC}\n\n"

  # Pod statuses
  info "Pod statuses in namespace '${NAMESPACE}':"
  oc get pods -n "${NAMESPACE}" -o wide 2>/dev/null || warn "Could not retrieve pod statuses"
  echo ""

  # Route URL
  local route_host
  route_host=$(oc get route -n "${NAMESPACE}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  if [[ -n "${route_host}" ]]; then
    ok "Airbyte UI available at: https://${route_host}"
  else
    warn "No Route found — Airbyte UI may not be externally accessible"
  fi
  echo ""

  # Warnings: pods not in Running/Completed state
  local problem_pods
  problem_pods=$(oc get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | grep -v -E 'Running|Completed' || true)
  if [[ -n "${problem_pods}" ]]; then
    warn "The following pods are not in Running/Completed state:"
    echo "${problem_pods}"
  else
    ok "All pods are healthy"
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  banner
  check_prerequisites
  echo ""
  create_namespace
  echo ""
  add_helm_repo
  echo ""
  deploy_airbyte
  echo ""
  wait_for_pods
  echo ""
  apply_route
  print_summary

  ok "Deployment complete"
}

main "$@"
