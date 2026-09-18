#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 04-configure-airbyte.sh
#
# Configure Airbyte via its Public API (/api/public/v1/) to sync data from
# a PostgreSQL source to a PostgreSQL destination in the airbyte_output schema.
#
# Airbyte V2 uses the public API — the internal /api/v1/ endpoints return 404.
# Auth is disabled in our openshift-values.yaml (global.auth.enabled: false).
###############################################################################

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
NAMESPACE="airbyte-validation"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="${SCRIPT_DIR}/../reports"

PG_HOST="postgresql.${NAMESPACE}.svc.cluster.local"
PG_PORT=5432
PG_DATABASE="sample_data"
PG_USER="airbyte_test"
PG_PASSWORD="testpass123"
DEST_SCHEMA="airbyte_output"

API_HEALTH_TIMEOUT=300
SYNC_POLL_INTERVAL=15
SYNC_TIMEOUT=600

# Well-known Airbyte connector definition UUIDs
POSTGRES_SOURCE_DEF_ID="decd338e-5647-4c0b-adf4-da0e75f5a750"
POSTGRES_DEST_DEF_ID="25c5221d-dce2-4163-ade9-739ef790f503"

PORT_FORWARD_PID=""

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
step()    { printf "\n${BOLD}${CYAN}==>${NC} ${BOLD}%s${NC}\n" "$*"; }

# ---------------------------------------------------------------------------
# api_get <path>
# ---------------------------------------------------------------------------
api_get() {
  local path="$1"
  local url="${API_BASE}${path}"
  local response http_code body

  response=$(curl -s -w "\n%{http_code}" "${url}") || true
  http_code=$(echo "${response}" | tail -n1)
  body=$(echo "${response}" | sed '$d')

  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    error "API GET ${path} -> HTTP ${http_code}"
    error "Response: ${body}"
    return 1
  fi
  echo "${body}"
}

# ---------------------------------------------------------------------------
# api_post <path> [json_body]
# ---------------------------------------------------------------------------
api_post() {
  local path="$1"
  local data="${2:-{}}"
  local url="${API_BASE}${path}"
  local response http_code body

  response=$(curl -s -w "\n%{http_code}" \
    -H "Content-Type: application/json" \
    -X POST -d "${data}" "${url}") || true
  http_code=$(echo "${response}" | tail -n1)
  body=$(echo "${response}" | sed '$d')

  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    error "API POST ${path} -> HTTP ${http_code}"
    error "Response: ${body}"
    return 1
  fi
  echo "${body}"
}

# ---------------------------------------------------------------------------
# Resolve the Airbyte server URL (Route > port-forward fallback)
# ---------------------------------------------------------------------------
resolve_airbyte_url() {
  step "Resolving Airbyte server URL"

  local route_host
  route_host=$(oc get route -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)

  if [[ -n "${route_host}" ]]; then
    local tls
    tls=$(oc get route -n "${NAMESPACE}" \
      -o jsonpath='{.items[0].spec.tls}' 2>/dev/null || true)
    if [[ -n "${tls}" && "${tls}" != "{}" ]]; then
      AIRBYTE_URL="https://${route_host}"
    else
      AIRBYTE_URL="http://${route_host}"
    fi
    API_BASE="${AIRBYTE_URL}/api/public/v1"
    success "Found Route: ${AIRBYTE_URL}"
    return 0
  fi

  # Fallback: port-forward to server service
  local svc_name
  svc_name=$(oc get svc -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E 'airbyte.*server' | head -n1 || true)

  if [[ -z "${svc_name}" ]]; then
    error "Could not find an Airbyte server service in namespace '${NAMESPACE}'"
    oc get svc -n "${NAMESPACE}" 2>/dev/null || true
    exit 1
  fi

  local svc_port
  svc_port=$(oc get svc "${svc_name}" -n "${NAMESPACE}" \
    -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8001")

  local local_port=8042
  lsof -ti :"${local_port}" 2>/dev/null | xargs kill -9 2>/dev/null || true

  info "Setting up port-forward to ${svc_name}:${svc_port}..."
  oc port-forward "svc/${svc_name}" "${local_port}:${svc_port}" \
    -n "${NAMESPACE}" &>/dev/null &
  PORT_FORWARD_PID=$!
  sleep 3

  if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
    error "Port-forward to ${svc_name} failed to start"
    exit 1
  fi

  AIRBYTE_URL="http://localhost:${local_port}"
  API_BASE="${AIRBYTE_URL}/api/public/v1"
  success "Port-forward active: ${AIRBYTE_URL} -> ${svc_name}:${svc_port} (PID ${PORT_FORWARD_PID})"
}

# ---------------------------------------------------------------------------
# Cleanup port-forward on exit
# ---------------------------------------------------------------------------
cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    info "Cleaning up port-forward (PID ${PORT_FORWARD_PID})..."
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Wait for API health
# ---------------------------------------------------------------------------
wait_for_api() {
  step "Waiting for Airbyte Public API to become healthy"

  local elapsed=0
  while [[ ${elapsed} -lt ${API_HEALTH_TIMEOUT} ]]; do
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" \
      "${API_BASE}/health" 2>/dev/null || echo "000")

    if [[ "${status}" == "200" ]]; then
      success "Airbyte Public API is healthy"
      return 0
    fi

    # Fallback: try listing workspaces as a health check
    if [[ "${status}" != "200" ]]; then
      status=$(curl -s -o /dev/null -w "%{http_code}" \
        "${API_BASE}/workspaces" 2>/dev/null || echo "000")
      if [[ "${status}" == "200" ]]; then
        success "Airbyte Public API is healthy (workspace list OK)"
        return 0
      fi
    fi

    info "API not ready yet (HTTP ${status}), retrying in 5s... (${elapsed}/${API_HEALTH_TIMEOUT}s)"
    sleep 5
    elapsed=$((elapsed + 5))
  done

  error "Airbyte API did not become healthy within ${API_HEALTH_TIMEOUT}s"
  exit 1
}

# ---------------------------------------------------------------------------
# Get workspace
# ---------------------------------------------------------------------------
setup_workspace() {
  step "Getting Airbyte workspace"

  local result
  result=$(api_get "/workspaces")

  WORKSPACE_ID=$(echo "${result}" | jq -r '.data[0].workspaceId')
  WORKSPACE_NAME=$(echo "${result}" | jq -r '.data[0].name')

  if [[ -z "${WORKSPACE_ID}" || "${WORKSPACE_ID}" == "null" ]]; then
    error "No workspaces found — Airbyte may not be fully initialized"
    exit 1
  fi

  success "Using workspace: ${WORKSPACE_NAME} (${WORKSPACE_ID})"
}

# ---------------------------------------------------------------------------
# Create PostgreSQL source
# ---------------------------------------------------------------------------
create_source() {
  step "Creating PostgreSQL source"

  # Check if source already exists
  local existing
  existing=$(api_get "/sources?workspaceIds=${WORKSPACE_ID}")
  SOURCE_ID=$(echo "${existing}" | jq -r \
    '.data[] | select(.name == "OpenShift Validation - PostgreSQL") | .sourceId' \
    | head -n1)

  if [[ -n "${SOURCE_ID}" && "${SOURCE_ID}" != "null" ]]; then
    success "Source already exists: ${SOURCE_ID}"
    return 0
  fi

  info "Creating source with host=${PG_HOST}, database=${PG_DATABASE}..."

  local result
  result=$(api_post "/sources" "{
    \"definitionId\": \"${POSTGRES_SOURCE_DEF_ID}\",
    \"workspaceId\": \"${WORKSPACE_ID}\",
    \"name\": \"OpenShift Validation - PostgreSQL\",
    \"configuration\": {
      \"host\": \"${PG_HOST}\",
      \"port\": ${PG_PORT},
      \"database\": \"${PG_DATABASE}\",
      \"username\": \"${PG_USER}\",
      \"password\": \"${PG_PASSWORD}\",
      \"schemas\": [\"public\"],
      \"ssl_mode\": {\"mode\": \"disable\"},
      \"tunnel_method\": {\"tunnel_method\": \"NO_TUNNEL\"},
      \"replication_method\": {\"method\": \"Standard\"}
    }
  }")

  SOURCE_ID=$(echo "${result}" | jq -r '.sourceId')

  if [[ -z "${SOURCE_ID}" || "${SOURCE_ID}" == "null" ]]; then
    error "Failed to create source — response:"
    echo "${result}" | jq . 2>/dev/null || echo "${result}"
    exit 1
  fi

  success "Created PostgreSQL source: ${SOURCE_ID}"
}

# ---------------------------------------------------------------------------
# Create PostgreSQL destination (writes to airbyte_output schema)
# ---------------------------------------------------------------------------
create_destination() {
  step "Creating PostgreSQL destination"

  # Check for existing destination
  local existing
  existing=$(api_get "/destinations?workspaceIds=${WORKSPACE_ID}")
  DESTINATION_ID=$(echo "${existing}" | jq -r \
    '.data[] | select(.name == "OpenShift Validation - PG Destination") | .destinationId' \
    | head -n1)

  if [[ -n "${DESTINATION_ID}" && "${DESTINATION_ID}" != "null" ]]; then
    success "Destination already exists: ${DESTINATION_ID}"
    return 0
  fi

  info "Creating PostgreSQL destination writing to schema '${DEST_SCHEMA}'..."

  local result
  result=$(api_post "/destinations" "{
    \"definitionId\": \"${POSTGRES_DEST_DEF_ID}\",
    \"workspaceId\": \"${WORKSPACE_ID}\",
    \"name\": \"OpenShift Validation - PG Destination\",
    \"configuration\": {
      \"host\": \"${PG_HOST}\",
      \"port\": ${PG_PORT},
      \"database\": \"${PG_DATABASE}\",
      \"username\": \"${PG_USER}\",
      \"password\": \"${PG_PASSWORD}\",
      \"schema\": \"${DEST_SCHEMA}\",
      \"ssl_mode\": {\"mode\": \"disable\"},
      \"tunnel_method\": {\"tunnel_method\": \"NO_TUNNEL\"}
    }
  }")

  DESTINATION_ID=$(echo "${result}" | jq -r '.destinationId')

  if [[ -z "${DESTINATION_ID}" || "${DESTINATION_ID}" == "null" ]]; then
    error "Failed to create destination — response:"
    echo "${result}" | jq . 2>/dev/null || echo "${result}"
    exit 1
  fi

  success "Created PostgreSQL destination: ${DESTINATION_ID}"
}

# ---------------------------------------------------------------------------
# Discover schema and create connection
# ---------------------------------------------------------------------------
discover_and_create_connection() {
  step "Discovering schema and creating connection"

  # Check if connection already exists
  local existing
  existing=$(api_get "/connections?workspaceIds=${WORKSPACE_ID}")
  CONNECTION_ID=$(echo "${existing}" | jq -r \
    '.data[] | select(.name == "OpenShift Validation Sync") | .connectionId' \
    | head -n1)

  if [[ -n "${CONNECTION_ID}" && "${CONNECTION_ID}" != "null" ]]; then
    success "Connection already exists: ${CONNECTION_ID}"
    return 0
  fi

  # Discover source schema
  info "Running schema discovery (this may take 30-60s)..."
  local catalog_result streams stream_count

  if catalog_result=$(api_post "/sources/${SOURCE_ID}/discover" "{}"); then
    streams=$(echo "${catalog_result}" | jq '[.catalog.streams[] | {
      name: .stream.name,
      syncMode: "full_refresh_overwrite"
    }]' 2>/dev/null)
    stream_count=$(echo "${streams}" | jq 'length' 2>/dev/null || echo "0")
  else
    warn "Schema discovery via public API failed — using known table names"
    streams='[
      {"name": "customers", "syncMode": "full_refresh_overwrite"},
      {"name": "documents", "syncMode": "full_refresh_overwrite"},
      {"name": "metadata", "syncMode": "full_refresh_overwrite"}
    ]'
    stream_count=3
  fi

  success "Configuring ${stream_count} stream(s)"

  # Create connection
  local result
  result=$(api_post "/connections" "{
    \"sourceId\": \"${SOURCE_ID}\",
    \"destinationId\": \"${DESTINATION_ID}\",
    \"name\": \"OpenShift Validation Sync\",
    \"schedule\": {\"scheduleType\": \"manual\"},
    \"namespaceDefinition\": \"destination\",
    \"configurations\": {
      \"streams\": ${streams}
    }
  }")

  CONNECTION_ID=$(echo "${result}" | jq -r '.connectionId')

  if [[ -z "${CONNECTION_ID}" || "${CONNECTION_ID}" == "null" ]]; then
    error "Failed to create connection — response:"
    echo "${result}" | jq . 2>/dev/null || echo "${result}"
    exit 1
  fi

  success "Created connection: ${CONNECTION_ID}"
}

# ---------------------------------------------------------------------------
# Trigger manual sync
# ---------------------------------------------------------------------------
trigger_sync() {
  step "Triggering manual sync"

  local result
  result=$(api_post "/jobs" "{
    \"connectionId\": \"${CONNECTION_ID}\",
    \"jobType\": \"sync\"
  }")

  JOB_ID=$(echo "${result}" | jq -r '.jobId')

  if [[ -z "${JOB_ID}" || "${JOB_ID}" == "null" ]]; then
    error "Failed to trigger sync — response:"
    echo "${result}" | jq . 2>/dev/null || echo "${result}"
    exit 1
  fi

  SYNC_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  success "Sync triggered — Job ID: ${JOB_ID}"
}

# ---------------------------------------------------------------------------
# Poll sync status until completion
# ---------------------------------------------------------------------------
poll_sync() {
  step "Polling sync status (timeout: ${SYNC_TIMEOUT}s)"

  local elapsed=0

  while [[ ${elapsed} -lt ${SYNC_TIMEOUT} ]]; do
    local result status rows bytes
    result=$(api_get "/jobs/${JOB_ID}")

    status=$(echo "${result}" | jq -r '.status')
    rows=$(echo "${result}" | jq -r '.rowsSynced // 0')
    bytes=$(echo "${result}" | jq -r '.bytesSynced // 0')

    case "${status}" in
      succeeded)
        SYNC_END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        SYNC_STATUS="succeeded"
        RECORDS_SYNCED="${rows}"
        BYTES_SYNCED="${bytes}"
        success "Sync completed — ${rows} rows, ${bytes} bytes"
        return 0
        ;;
      failed|cancelled)
        SYNC_END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        SYNC_STATUS="${status}"
        RECORDS_SYNCED="${rows}"
        BYTES_SYNCED="${bytes}"
        error "Sync ${status}"
        return 1
        ;;
      *)
        info "Status: ${status} | Rows: ${rows} | Bytes: ${bytes} (${elapsed}/${SYNC_TIMEOUT}s)"
        ;;
    esac

    sleep "${SYNC_POLL_INTERVAL}"
    elapsed=$((elapsed + SYNC_POLL_INTERVAL))
  done

  SYNC_END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  SYNC_STATUS="timeout"
  RECORDS_SYNCED="0"
  BYTES_SYNCED="0"
  error "Sync did not complete within ${SYNC_TIMEOUT}s"
  return 1
}

# ---------------------------------------------------------------------------
# Save results
# ---------------------------------------------------------------------------
save_results() {
  step "Saving sync results"

  jq -n \
    --arg job_id "${JOB_ID}" \
    --arg status "${SYNC_STATUS:-unknown}" \
    --arg rows "${RECORDS_SYNCED:-0}" \
    --arg bytes "${BYTES_SYNCED:-0}" \
    --arg start "${SYNC_START_TIME:-}" \
    --arg end "${SYNC_END_TIME:-}" \
    --arg connection_id "${CONNECTION_ID}" \
    --arg source_id "${SOURCE_ID}" \
    --arg dest_id "${DESTINATION_ID}" \
    --arg workspace_id "${WORKSPACE_ID}" \
    --arg url "${AIRBYTE_URL}" \
    --arg ns "${NAMESPACE}" \
    '{
      jobId: ($job_id | tonumber),
      status: $status,
      jobType: "sync",
      rowsSynced: ($rows | tonumber),
      bytesSynced: ($bytes | tonumber),
      startTime: $start,
      endTime: $end,
      connectionId: $connection_id,
      sourceId: $source_id,
      destinationId: $dest_id,
      workspaceId: $workspace_id,
      airbyteUrl: $url,
      namespace: $ns
    }' > "${REPORTS_DIR}/sync-results.json"

  success "Results saved to ${REPORTS_DIR}/sync-results.json"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  printf "\n${BOLD}========================================${NC}\n"
  printf "${BOLD} Sync Summary${NC}\n"
  printf "${BOLD}========================================${NC}\n\n"

  printf "${BOLD}  %-20s${NC} %s\n" "Workspace:"    "${WORKSPACE_NAME} (${WORKSPACE_ID})"
  printf "${BOLD}  %-20s${NC} %s\n" "Source:"        "PostgreSQL (${SOURCE_ID})"
  printf "${BOLD}  %-20s${NC} %s\n" "Destination:"   "PostgreSQL/${DEST_SCHEMA} (${DESTINATION_ID})"
  printf "${BOLD}  %-20s${NC} %s\n" "Connection:"    "${CONNECTION_ID}"
  printf "${BOLD}  %-20s${NC} %s\n" "Job ID:"        "${JOB_ID}"
  printf "${BOLD}  %-20s${NC} %s\n" "Status:"        "${SYNC_STATUS:-unknown}"
  printf "${BOLD}  %-20s${NC} %s\n" "Records:"       "${RECORDS_SYNCED:-0}"
  printf "${BOLD}  %-20s${NC} %s\n" "Bytes:"         "${BYTES_SYNCED:-0}"
  printf "${BOLD}  %-20s${NC} %s\n" "Started:"       "${SYNC_START_TIME:-n/a}"
  printf "${BOLD}  %-20s${NC} %s\n" "Completed:"     "${SYNC_END_TIME:-n/a}"
  printf "\n"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  printf "\n${BOLD}========================================${NC}\n"
  printf "${BOLD} Airbyte Configuration & Sync${NC}\n"
  printf "${BOLD} (Public API v1)${NC}\n"
  printf "${BOLD}========================================${NC}\n\n"

  for cmd in oc curl jq; do
    if ! command -v "${cmd}" &>/dev/null; then
      error "${cmd} CLI not found — install it first"
      exit 1
    fi
  done
  success "Prerequisites met (oc, curl, jq available; logged in as $(oc whoami))"

  mkdir -p "${REPORTS_DIR}"

  resolve_airbyte_url
  wait_for_api
  setup_workspace
  create_source
  create_destination
  discover_and_create_connection
  trigger_sync

  local sync_ok=true
  poll_sync || sync_ok=false

  save_results
  print_summary

  if [[ "${sync_ok}" == "true" ]]; then
    success "Airbyte configuration and sync completed successfully"
  else
    error "Sync did not complete successfully — check the report for details"
    exit 1
  fi
}

main "$@"
