#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# 02-verify-coexistence.sh
# Verify that RHOAI and Airbyte coexist without conflicts on OpenShift.
# ---------------------------------------------------------------------------

RHOAI_NS="redhat-ods-applications"
AIRBYTE_NS="airbyte-validation"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/../reports"
REPORT_FILE="${REPORT_DIR}/coexistence-check.txt"

# -- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# -- Counters ---------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

# -- Helpers ----------------------------------------------------------------
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

log()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
pass() { printf "${GREEN}[PASS]${RESET}  %s\n" "$*"; ((PASS_COUNT++)); }
fail() { printf "${RED}[FAIL]${RESET}  %s\n" "$*"; ((FAIL_COUNT++)); }
warn() { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; ((WARN_COUNT++)); }
header() {
  printf "\n${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
  printf "${BOLD}  %s${RESET}\n" "$*"
  printf "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
}

# Ensure report directory exists
mkdir -p "${REPORT_DIR}"

# Start report capture (both stdout and file, stripping ANSI codes from file)
exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' > "${REPORT_FILE}")) 2>&1

printf "${BOLD}Coexistence Verification Report${RESET}\n"
printf "Generated: %s\n" "$(timestamp)"
printf "Cluster:   %s\n" "$(oc whoami --show-server 2>/dev/null || echo 'unknown')"
printf "User:      %s\n" "$(oc whoami 2>/dev/null || echo 'unknown')"

# ===================================================================
# 1. RHOAI Health
# ===================================================================
header "1. RHOAI Health Check"

# -- 1a. Pods in redhat-ods-applications --------------------------------
log "Checking pods in ${RHOAI_NS}..."
RHOAI_PODS_JSON="$(oc get pods -n "${RHOAI_NS}" -o json 2>/dev/null || echo '{}')"
RHOAI_TOTAL="$(echo "${RHOAI_PODS_JSON}" | jq '.items | length')"

if [[ "${RHOAI_TOTAL}" -eq 0 ]]; then
  fail "No pods found in ${RHOAI_NS} -- namespace may not exist or is empty"
else
  NOT_RUNNING="$(echo "${RHOAI_PODS_JSON}" | jq '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")] | length')"
  NOT_READY="$(echo "${RHOAI_PODS_JSON}" | jq '[.items[] | select(.status.phase == "Running") | select(.status.containerStatuses[]? | select(.ready == false))] | length')"

  if [[ "${NOT_RUNNING}" -eq 0 && "${NOT_READY}" -eq 0 ]]; then
    pass "All ${RHOAI_TOTAL} pods in ${RHOAI_NS} are Running/Ready"
  else
    fail "${NOT_RUNNING} pod(s) not Running, ${NOT_READY} pod(s) not Ready in ${RHOAI_NS}"
    echo "${RHOAI_PODS_JSON}" | jq -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | "  - \(.metadata.name): \(.status.phase)"'
  fi
fi

# -- 1b. DataScienceCluster CR ------------------------------------------
log "Checking DataScienceCluster CR..."
DSC_JSON="$(oc get datasciencecluster -o json 2>/dev/null || echo '{}')"
DSC_COUNT="$(echo "${DSC_JSON}" | jq '.items | length')"

if [[ "${DSC_COUNT}" -eq 0 ]]; then
  fail "No DataScienceCluster CR found"
else
  DSC_NAME="$(echo "${DSC_JSON}" | jq -r '.items[0].metadata.name')"
  log "DataScienceCluster: ${DSC_NAME}"

  # Check component management states
  COMPONENTS="$(echo "${DSC_JSON}" | jq -r '.items[0].spec.components // {} | to_entries[] | "\(.key)=\(.value.managementState // "unknown")"' 2>/dev/null)"
  ALL_MANAGED=true

  if [[ -z "${COMPONENTS}" ]]; then
    warn "Could not read component management states from DataScienceCluster"
  else
    while IFS= read -r entry; do
      comp_name="${entry%%=*}"
      comp_state="${entry##*=}"
      if [[ "${comp_state}" == "Managed" ]]; then
        printf "  ${GREEN}%-30s %s${RESET}\n" "${comp_name}" "${comp_state}"
      elif [[ "${comp_state}" == "Removed" ]]; then
        printf "  ${YELLOW}%-30s %s${RESET}\n" "${comp_name}" "${comp_state}"
      else
        printf "  ${RED}%-30s %s${RESET}\n" "${comp_name}" "${comp_state}"
        ALL_MANAGED=false
      fi
    done <<< "${COMPONENTS}"

    if ${ALL_MANAGED}; then
      pass "DataScienceCluster components are in expected states"
    else
      warn "Some DataScienceCluster components are not Managed or Removed"
    fi
  fi
fi

# -- 1c. Error events since Airbyte deployment ---------------------------
log "Checking for error events in ${RHOAI_NS} (last 30 minutes)..."
ERROR_EVENTS="$(oc get events -n "${RHOAI_NS}" --field-selector type!=Normal -o json 2>/dev/null || echo '{"items":[]}')"
ERROR_EVENT_COUNT="$(echo "${ERROR_EVENTS}" | jq '.items | length')"

if [[ "${ERROR_EVENT_COUNT}" -eq 0 ]]; then
  pass "No error events in ${RHOAI_NS}"
else
  warn "${ERROR_EVENT_COUNT} non-normal event(s) in ${RHOAI_NS}:"
  echo "${ERROR_EVENTS}" | jq -r '.items[] | "  [\(.type)] \(.reason): \(.message // "no message")" ' | head -20
fi

# ===================================================================
# 2. Airbyte Health
# ===================================================================
header "2. Airbyte Health Check"

# -- 2a. Pods in airbyte-validation -------------------------------------
log "Checking pods in ${AIRBYTE_NS}..."
AIRBYTE_PODS_JSON="$(oc get pods -n "${AIRBYTE_NS}" -o json 2>/dev/null || echo '{}')"
AIRBYTE_TOTAL="$(echo "${AIRBYTE_PODS_JSON}" | jq '.items | length')"

if [[ "${AIRBYTE_TOTAL}" -eq 0 ]]; then
  fail "No pods found in ${AIRBYTE_NS} -- namespace may not exist or is empty"
else
  AB_NOT_RUNNING="$(echo "${AIRBYTE_PODS_JSON}" | jq '[.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded")] | length')"
  AB_NOT_READY="$(echo "${AIRBYTE_PODS_JSON}" | jq '[.items[] | select(.status.phase == "Running") | select(.status.containerStatuses[]? | select(.ready == false))] | length')"

  if [[ "${AB_NOT_RUNNING}" -eq 0 && "${AB_NOT_READY}" -eq 0 ]]; then
    pass "All ${AIRBYTE_TOTAL} pods in ${AIRBYTE_NS} are Running/Ready"
  else
    fail "${AB_NOT_RUNNING} pod(s) not Running, ${AB_NOT_READY} pod(s) not Ready in ${AIRBYTE_NS}"
    echo "${AIRBYTE_PODS_JSON}" | jq -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | "  - \(.metadata.name): \(.status.phase)"'
  fi
fi

# -- 2b. CrashLoopBackOff / Error detection ------------------------------
log "Checking for CrashLoopBackOff or Error states..."
CRASH_PODS="$(echo "${AIRBYTE_PODS_JSON}" | jq -r '[.items[] | select(.status.containerStatuses[]? | .state.waiting.reason == "CrashLoopBackOff" or .state.waiting.reason == "Error")] | unique_by(.metadata.name) | .[].metadata.name' 2>/dev/null)"

if [[ -z "${CRASH_PODS}" ]]; then
  pass "No CrashLoopBackOff or Error states in ${AIRBYTE_NS}"
else
  fail "Pods in CrashLoopBackOff/Error state:"
  while IFS= read -r pod; do
    printf "  ${RED}- %s${RESET}\n" "${pod}"
  done <<< "${CRASH_PODS}"
fi

# ===================================================================
# 3. Resource Audit
# ===================================================================
header "3. Resource Audit"

# -- 3a. Cluster node utilization ----------------------------------------
log "Cluster node utilization:"
printf "\n"
oc adm top nodes 2>/dev/null || warn "Could not retrieve node metrics (metrics-server may not be available)"
printf "\n"

# -- 3b. Airbyte resource usage ------------------------------------------
log "Airbyte pod resource usage (${AIRBYTE_NS}):"
printf "\n"
oc adm top pods -n "${AIRBYTE_NS}" 2>/dev/null || warn "Could not retrieve pod metrics for ${AIRBYTE_NS}"
printf "\n"

# -- 3c. RHOAI resource usage -------------------------------------------
log "RHOAI pod resource usage (${RHOAI_NS}):"
printf "\n"
oc adm top pods -n "${RHOAI_NS}" 2>/dev/null || warn "Could not retrieve pod metrics for ${RHOAI_NS}"
printf "\n"

# ===================================================================
# 4. CRD Conflict Check
# ===================================================================
header "4. CRD Conflict Check"

log "Retrieving all cluster CRDs..."
ALL_CRDS="$(oc get crds -o json 2>/dev/null || echo '{"items":[]}')"

# Identify Airbyte CRDs (group contains "airbyte")
AIRBYTE_CRDS="$(echo "${ALL_CRDS}" | jq -r '[.items[] | select(.spec.group | test("airbyte"; "i"))] | .[].metadata.name' 2>/dev/null)"

# Identify RHOAI / ODH CRDs (group contains "opendatahub" or "rhods")
RHOAI_CRDS="$(echo "${ALL_CRDS}" | jq -r '[.items[] | select(.spec.group | test("opendatahub|rhods|datasciencecluster|kfdef"; "i"))] | .[].metadata.name' 2>/dev/null)"

if [[ -z "${AIRBYTE_CRDS}" ]]; then
  log "No Airbyte-specific CRDs detected on the cluster"
else
  log "Airbyte CRDs found:"
  while IFS= read -r crd; do
    printf "  - %s\n" "${crd}"
  done <<< "${AIRBYTE_CRDS}"
fi

if [[ -z "${RHOAI_CRDS}" ]]; then
  log "No RHOAI-specific CRDs detected on the cluster"
else
  log "RHOAI CRDs found:"
  while IFS= read -r crd; do
    printf "  - %s\n" "${crd}"
  done <<< "${RHOAI_CRDS}"
fi

# Check for group-level conflicts (same API group used by both)
CONFLICT_FOUND=false
if [[ -n "${AIRBYTE_CRDS}" && -n "${RHOAI_CRDS}" ]]; then
  AIRBYTE_GROUPS="$(echo "${ALL_CRDS}" | jq -r '[.items[] | select(.spec.group | test("airbyte"; "i"))] | .[].spec.group' | sort -u)"
  RHOAI_GROUPS="$(echo "${ALL_CRDS}" | jq -r '[.items[] | select(.spec.group | test("opendatahub|rhods|datasciencecluster|kfdef"; "i"))] | .[].spec.group' | sort -u)"

  while IFS= read -r ag; do
    [[ -z "${ag}" ]] && continue
    if echo "${RHOAI_GROUPS}" | grep -qF "${ag}"; then
      fail "CRD API group conflict: '${ag}' is claimed by both Airbyte and RHOAI"
      CONFLICT_FOUND=true
    fi
  done <<< "${AIRBYTE_GROUPS}"
fi

# Also check for exact CRD name overlaps
if [[ -n "${AIRBYTE_CRDS}" && -n "${RHOAI_CRDS}" ]]; then
  OVERLAPPING="$(comm -12 <(echo "${AIRBYTE_CRDS}" | sort) <(echo "${RHOAI_CRDS}" | sort))"
  if [[ -n "${OVERLAPPING}" ]]; then
    fail "Overlapping CRD names between Airbyte and RHOAI:"
    echo "${OVERLAPPING}" | while IFS= read -r crd; do
      printf "  ${RED}- %s${RESET}\n" "${crd}"
    done
    CONFLICT_FOUND=true
  fi
fi

if ! ${CONFLICT_FOUND}; then
  pass "No CRD conflicts between Airbyte and RHOAI"
fi

# ===================================================================
# 5. Summary Report
# ===================================================================
header "5. Coexistence Verification Summary"

TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))

printf "\n"
printf "  ${GREEN}Passed:   %d${RESET}\n" "${PASS_COUNT}"
printf "  ${RED}Failed:   %d${RESET}\n" "${FAIL_COUNT}"
printf "  ${YELLOW}Warnings: %d${RESET}\n" "${WARN_COUNT}"
printf "  Total:    %d\n" "${TOTAL}"
printf "\n"

if [[ "${FAIL_COUNT}" -eq 0 ]]; then
  printf "  ${GREEN}${BOLD}OVERALL: PASS${RESET}\n"
  printf "  RHOAI and Airbyte are coexisting without detected conflicts.\n"
else
  printf "  ${RED}${BOLD}OVERALL: FAIL${RESET}\n"
  printf "  ${FAIL_COUNT} check(s) failed. Review details above.\n"
fi

printf "\n"
log "Detailed report saved to: ${REPORT_FILE}"
printf "\n"

# Exit with failure if any checks failed
[[ "${FAIL_COUNT}" -eq 0 ]]
