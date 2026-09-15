#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

FAILURES=()

pass() {
  printf "  ${GREEN}PASS${RESET}  %s\n" "$1"
}

fail() {
  printf "  ${RED}FAIL${RESET}  %s\n" "$1"
  FAILURES+=("$1")
}

info() {
  printf "  ${YELLOW}INFO${RESET}  %s\n" "$1"
}

header() {
  printf "\n${BOLD}%s${RESET}\n" "$1"
}

# ---------------------------------------------------------------
# 1. Required CLI tools
# ---------------------------------------------------------------
header "Checking required tools..."

REQUIRED_TOOLS=(oc helm jq yq curl podman)

for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" &>/dev/null; then
    version=$("$tool" version --short 2>/dev/null \
           || "$tool" version 2>/dev/null \
           || "$tool" --version 2>/dev/null \
           || echo "unknown")
    # Collapse to first line
    version=$(echo "$version" | head -n1)
    pass "$tool ($version)"
  else
    fail "$tool is not installed"
  fi
done

# ---------------------------------------------------------------
# 2. OpenShift login
# ---------------------------------------------------------------
header "Checking OpenShift authentication..."

if oc whoami &>/dev/null; then
  user=$(oc whoami)
  pass "Logged in as $user"
else
  fail "Not logged in to OpenShift (oc whoami failed)"
fi

# ---------------------------------------------------------------
# 3. Cluster-admin privileges
# ---------------------------------------------------------------
header "Checking cluster-admin privileges..."

if oc auth can-i '*' '*' --all-namespaces &>/dev/null; then
  pass "cluster-admin confirmed"
else
  fail "Current user lacks cluster-admin privileges"
fi

# ---------------------------------------------------------------
# 4. OpenShift version
# ---------------------------------------------------------------
header "Checking OpenShift version..."

if oc_version=$(oc version 2>/dev/null); then
  server_version=$(echo "$oc_version" | grep -i 'server' | head -n1 || true)
  if [[ -n "$server_version" ]]; then
    pass "$server_version"
  else
    # Fall back to cluster version from API
    cluster_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
    if [[ -n "$cluster_version" ]]; then
      pass "OpenShift $cluster_version"
    else
      info "Could not determine server version"
    fi
  fi
else
  fail "Unable to query OpenShift version"
fi

# ---------------------------------------------------------------
# 5. RHOAI (rhods-operator CSV)
# ---------------------------------------------------------------
header "Checking Red Hat OpenShift AI (RHOAI)..."

rhoai_csv=$(oc get csv -A 2>/dev/null | grep -i 'rhods-operator' | head -n1 || true)
if [[ -n "$rhoai_csv" ]]; then
  csv_name=$(echo "$rhoai_csv" | awk '{print $2}')
  info "rhods-operator CSV found: $csv_name"
fi

rhoai_pods=$(oc get pods -n redhat-ods-applications --no-headers 2>/dev/null | grep -c 'Running' || echo 0)
if [[ "$rhoai_pods" -gt 0 ]]; then
  pass "RHOAI is operational ($rhoai_pods pods running in redhat-ods-applications)"
else
  fail "No running RHOAI pods found in redhat-ods-applications"
fi

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
header "Summary"

if [[ ${#FAILURES[@]} -eq 0 ]]; then
  printf "\n${GREEN}${BOLD}All prerequisite checks passed.${RESET}\n\n"
  exit 0
else
  printf "\n${RED}${BOLD}%d check(s) failed:${RESET}\n" "${#FAILURES[@]}"
  for f in "${FAILURES[@]}"; do
    printf "  ${RED}-${RESET} %s\n" "$f"
  done
  printf "\n"
  exit 1
fi
