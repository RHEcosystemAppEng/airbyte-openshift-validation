#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 05-configure-rag-connectors.sh
#
# Create the Airbyte connectors used by the RAG ingestion scenario:
#
#   Google Drive legal      ─┐
#   Google Drive compliance ─┼─> S3-compatible landing destination
#   S3 financial statements ┘
#   PostgreSQL SEC data     ───> PostgreSQL destination
#
# Connector configuration is read from local JSON files. Those files are
# intentionally not checked in because they contain credentials. The script
# creates missing resources and reuses resources with the same names, so it is
# safe to run again after a partial setup.
#
# Airbyte V2 uses the Public API (/api/public/v1/). Connector definition IDs
# are configurable because self-managed Airbyte installations can have
# different connector catalogs and versions.
###############################################################################

NAMESPACE="${NAMESPACE:-airbyte-validation}"

AIRBYTE_URL="${AIRBYTE_URL:-}"
API_BASE="${API_BASE:-}"
AIRBYTE_API_TOKEN="${AIRBYTE_API_TOKEN:-}"
WORKSPACE_ID="${AIRBYTE_WORKSPACE_ID:-}"
PORT_FORWARD_PID=""

API_HEALTH_TIMEOUT="${API_HEALTH_TIMEOUT:-300}"
API_CONNECT_TIMEOUT="${API_CONNECT_TIMEOUT:-5}"
API_REQUEST_TIMEOUT="${API_REQUEST_TIMEOUT:-30}"

# Connector definition IDs. Override these if the installed Airbyte catalog
# uses different definitions.
GOOGLE_DRIVE_SOURCE_DEF_ID="${GOOGLE_DRIVE_SOURCE_DEF_ID:-9f8dda77-1048-4368-815b-269bf54ee9b8}"
S3_SOURCE_DEF_ID="${S3_SOURCE_DEF_ID:-69589781-7828-43c5-9f63-8925b1c1ccc2}"
POSTGRES_SOURCE_DEF_ID="${POSTGRES_SOURCE_DEF_ID:-decd338e-5647-4c0b-adf4-da0e75f5a750}"
S3_DESTINATION_DEF_ID="${S3_DESTINATION_DEF_ID:-4816b78f-1489-44c1-9060-4b19d5fa9362}"
POSTGRES_DESTINATION_DEF_ID="${POSTGRES_DESTINATION_DEF_ID:-25c5221d-dce2-4163-ade9-739ef790f503}"

# Resource names can be changed without changing the connector configs.
GDRIVE_LEGAL_NAME="${GDRIVE_LEGAL_NAME:-RAG - Google Drive - Legal}"
GDRIVE_COMPLIANCE_NAME="${GDRIVE_COMPLIANCE_NAME:-RAG - Google Drive - Compliance}"
S3_SOURCE_NAME="${S3_SOURCE_NAME:-RAG - S3 - Financial Statements}"
POSTGRES_SOURCE_NAME="${POSTGRES_SOURCE_NAME:-RAG - PostgreSQL - SEC Data}"
S3_DESTINATION_NAME="${S3_DESTINATION_NAME:-RAG - S3 Landing Zone}"
POSTGRES_DESTINATION_NAME="${POSTGRES_DESTINATION_NAME:-RAG - PostgreSQL Landing}"

# JSON config files. Set these to files outside the repository.
GDRIVE_LEGAL_CONFIG_FILE="${GDRIVE_LEGAL_CONFIG_FILE:-}"
GDRIVE_COMPLIANCE_CONFIG_FILE="${GDRIVE_COMPLIANCE_CONFIG_FILE:-}"
S3_SOURCE_CONFIG_FILE="${S3_SOURCE_CONFIG_FILE:-}"
POSTGRES_SOURCE_CONFIG_FILE="${POSTGRES_SOURCE_CONFIG_FILE:-}"
S3_DESTINATION_CONFIG_FILE="${S3_DESTINATION_CONFIG_FILE:-}"
POSTGRES_DESTINATION_CONFIG_FILE="${POSTGRES_DESTINATION_CONFIG_FILE:-}"

# The PostgreSQL source config must point to an already deployed and seeded
# database. This script does not deploy PostgreSQL or load the SEC corpus.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
step()    { printf "\n${BOLD}${CYAN}==>${NC} ${BOLD}%s${NC}\n" "$*"; }

api_get() {
  local path="$1"
  local response http_code body
  if [[ -n "${AIRBYTE_API_TOKEN}" ]]; then
    response=$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_REQUEST_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${AIRBYTE_API_TOKEN}" \
      -w "\n%{http_code}" "${API_BASE}${path}") || true
  else
    response=$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_REQUEST_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -w "\n%{http_code}" "${API_BASE}${path}") || true
  fi
  http_code="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"

  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    error "API GET ${path} -> HTTP ${http_code}"
    error "Response: ${body}"
    return 1
  fi
  printf '%s\n' "${body}"
}

api_post() {
  local path="$1"
  local data="${2:-{}}"
  local response http_code body
  if [[ -n "${AIRBYTE_API_TOKEN}" ]]; then
    response=$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_REQUEST_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${AIRBYTE_API_TOKEN}" \
      -X POST -d "${data}" -w "\n%{http_code}" "${API_BASE}${path}") || true
  else
    response=$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_REQUEST_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -X POST -d "${data}" -w "\n%{http_code}" "${API_BASE}${path}") || true
  fi
  http_code="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"

  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    error "API POST ${path} -> HTTP ${http_code}"
    error "Response: ${body}"
    return 1
  fi
  printf '%s\n' "${body}"
}

api_patch() {
  local path="$1"
  local data="${2:-{}}"
  local response http_code body
  if [[ -n "${AIRBYTE_API_TOKEN}" ]]; then
    response=$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_REQUEST_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${AIRBYTE_API_TOKEN}" \
      -X PATCH -d "${data}" -w "\n%{http_code}" "${API_BASE}${path}") || true
  else
    response=$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_REQUEST_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -X PATCH -d "${data}" -w "\n%{http_code}" "${API_BASE}${path}") || true
  fi
  http_code="$(printf '%s\n' "${response}" | tail -n1)"
  body="$(printf '%s\n' "${response}" | sed '$d')"

  if [[ "${http_code}" -lt 200 || "${http_code}" -ge 300 ]]; then
    error "API PATCH ${path} -> HTTP ${http_code}"
    error "Response: ${body}"
    return 1
  fi
  printf '%s\n' "${body}"
}

api_status() {
  local path="$1"
  local response
  if [[ -n "${AIRBYTE_API_TOKEN}" ]]; then
    response="$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_REQUEST_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${AIRBYTE_API_TOKEN}" \
      -o /dev/null -w '%{http_code}' "${API_BASE}${path}" 2>/dev/null || echo 000)"
  else
    response="$(curl -sS --connect-timeout "${API_CONNECT_TIMEOUT}" --max-time "${API_REQUEST_TIMEOUT}" \
      -H "Content-Type: application/json" \
      -o /dev/null -w '%{http_code}' "${API_BASE}${path}" 2>/dev/null || echo 000)"
  fi
  printf '%s\n' "${response}"
}

resolve_airbyte_url() {
  if [[ -n "${API_BASE}" ]]; then
    AIRBYTE_URL="${AIRBYTE_URL:-${API_BASE%/api/public/v1}}"
    info "Using API base from environment: ${API_BASE}"
    return 0
  fi

  if [[ -n "${AIRBYTE_URL}" ]]; then
    API_BASE="${AIRBYTE_URL%/}/api/public/v1"
    info "Using Airbyte URL from environment: ${AIRBYTE_URL}"
    return 0
  fi

  step "Resolving Airbyte server URL"
  local route_host tls svc_name svc_port local_port
  route_host="$(oc get route -n "${NAMESPACE}" -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)"

  if [[ -n "${route_host}" ]]; then
    tls="$(oc get route -n "${NAMESPACE}" -o jsonpath='{.items[0].spec.tls}' 2>/dev/null || true)"
    if [[ -n "${tls}" && "${tls}" != "{}" ]]; then
      AIRBYTE_URL="https://${route_host}"
    else
      AIRBYTE_URL="http://${route_host}"
    fi
    API_BASE="${AIRBYTE_URL}/api/public/v1"
    success "Found Route: ${AIRBYTE_URL}"
    return 0
  fi

  svc_name="$(oc get svc -n "${NAMESPACE}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E 'airbyte.*server' | head -n1 || true)"
  if [[ -z "${svc_name}" ]]; then
    error "Could not find an Airbyte server service in namespace '${NAMESPACE}'"
    exit 1
  fi

  svc_port="$(oc get svc "${svc_name}" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo 8001)"
  local_port="${AIRBYTE_LOCAL_PORT:-8043}"
  info "Setting up port-forward to ${svc_name}:${svc_port}..."
  oc port-forward "svc/${svc_name}" "${local_port}:${svc_port}" -n "${NAMESPACE}" &>/dev/null &
  PORT_FORWARD_PID=$!
  sleep 3
  if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
    error "Port-forward to ${svc_name} failed to start"
    exit 1
  fi

  AIRBYTE_URL="http://localhost:${local_port}"
  API_BASE="${AIRBYTE_URL}/api/public/v1"
  success "Port-forward active: ${AIRBYTE_URL}"
}

cleanup() {
  if [[ -n "${PORT_FORWARD_PID}" ]]; then
    info "Cleaning up port-forward (PID ${PORT_FORWARD_PID})..."
    kill "${PORT_FORWARD_PID}" 2>/dev/null || true
    wait "${PORT_FORWARD_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

wait_for_api() {
  step "Waiting for Airbyte Public API"
  local elapsed=0 status
  while [[ ${elapsed} -lt ${API_HEALTH_TIMEOUT} ]]; do
    status="$(api_status /health)"
    if [[ "${status}" == 200 ]]; then
      success "Airbyte Public API is healthy"
      return 0
    fi
    status="$(api_status /workspaces)"
    if [[ "${status}" == 200 ]]; then
      success "Airbyte Public API is healthy (workspace list OK)"
      return 0
    fi
    info "API not ready (HTTP ${status}); retrying in 5s..."
    sleep 5
    elapsed=$((elapsed + 5))
  done
  error "Airbyte API did not become healthy within ${API_HEALTH_TIMEOUT}s"
  exit 1
}

setup_workspace() {
  if [[ -n "${WORKSPACE_ID}" ]]; then
    WORKSPACE_NAME="${AIRBYTE_WORKSPACE_NAME:-configured workspace}"
    success "Using workspace: ${WORKSPACE_NAME} (${WORKSPACE_ID})"
    return 0
  fi

  local result
  result="$(api_get "/workspaces")"
  WORKSPACE_ID="$(jq -r '.data[0].workspaceId // empty' <<<"${result}")"
  WORKSPACE_NAME="$(jq -r '.data[0].name // "unnamed"' <<<"${result}")"
  if [[ -z "${WORKSPACE_ID}" ]]; then
    error "No Airbyte workspaces found"
    exit 1
  fi
  success "Using workspace: ${WORKSPACE_NAME} (${WORKSPACE_ID})"
}

require_file() {
  local variable_name="$1"
  local file_path="$2"
  if [[ -z "${file_path}" ]]; then
    error "${variable_name} is required; see examples/airbyte/rag-connectors/"
    exit 1
  fi
  if [[ ! -f "${file_path}" ]]; then
    error "${variable_name} points to a missing file: ${file_path}"
    exit 1
  fi
  if ! jq -e 'type == "object"' "${file_path}" >/dev/null; then
    error "${file_path} must contain a JSON object"
    exit 1
  fi
}

create_or_reuse_source() {
  local name="$1" definition_id="$2" config_file="$3" variable_name="$4"
  local existing result source_id
  require_file "${variable_name}" "${config_file}"

  existing="$(api_get "/sources?workspaceIds=${WORKSPACE_ID}&limit=100")"
  source_id="$(jq -r --arg name "${name}" '.data[] | select(.name == $name) | .sourceId' <<<"${existing}" | head -n1)"
  if [[ -n "${source_id}" ]]; then
    success "Source already exists: ${name} (${source_id})" >&2
    printf '%s\n' "${source_id}"
    return 0
  fi

  if [[ -z "${definition_id}" ]]; then
    error "No connector definition ID configured for source '${name}'"
    error "Set the corresponding *_SOURCE_DEF_ID environment variable"
    exit 1
  fi
  info "Creating source: ${name}" >&2
  result="$(jq -n --arg definition_id "${definition_id}" --arg workspace_id "${WORKSPACE_ID}" \
    --arg name "${name}" --slurpfile configuration "${config_file}" \
    '{definitionId: $definition_id, workspaceId: $workspace_id, name: $name, configuration: $configuration[0]}')"
  result="$(api_post /sources "${result}")"
  source_id="$(jq -r '.sourceId // empty' <<<"${result}")"
  if [[ -z "${source_id}" ]]; then
    error "Airbyte did not return a sourceId for '${name}'"
    jq . <<<"${result}" 2>/dev/null || true
    exit 1
  fi
  success "Created source: ${name} (${source_id})" >&2
  printf '%s\n' "${source_id}"
}

create_or_reuse_destination() {
  local name="$1" definition_id="$2" config_file="$3" variable_name="$4"
  local existing result destination_id
  require_file "${variable_name}" "${config_file}"

  existing="$(api_get "/destinations?workspaceIds=${WORKSPACE_ID}&limit=100")"
  destination_id="$(jq -r --arg name "${name}" '.data[] | select(.name == $name) | .destinationId' <<<"${existing}" | head -n1)"
  if [[ -n "${destination_id}" ]]; then
    success "Destination already exists: ${name} (${destination_id})" >&2
    printf '%s\n' "${destination_id}"
    return 0
  fi

  if [[ -z "${definition_id}" ]]; then
    error "No connector definition ID configured for destination '${name}'"
    error "Set the corresponding *_DESTINATION_DEF_ID environment variable"
    exit 1
  fi
  info "Creating destination: ${name}" >&2
  result="$(jq -n --arg definition_id "${definition_id}" --arg workspace_id "${WORKSPACE_ID}" \
    --arg name "${name}" --slurpfile configuration "${config_file}" \
    '{definitionId: $definition_id, workspaceId: $workspace_id, name: $name, configuration: $configuration[0]}')"
  result="$(api_post /destinations "${result}")"
  destination_id="$(jq -r '.destinationId // empty' <<<"${result}")"
  if [[ -z "${destination_id}" ]]; then
    error "Airbyte did not return a destinationId for '${name}'"
    jq . <<<"${result}" 2>/dev/null || true
    exit 1
  fi
  success "Created destination: ${name} (${destination_id})" >&2
  printf '%s\n' "${destination_id}"
}

create_or_reuse_connection() {
  local name="$1" source_id="$2" destination_id="$3"
  local existing result connection_id detail streams

  info "Discovering streams for: ${name}"
  streams="$(discover_streams "${source_id}" "${destination_id}")"

  existing="$(api_get "/connections?workspaceIds=${WORKSPACE_ID}&limit=100")"
  connection_id="$(jq -r --arg name "${name}" '.data[] | select(.name == $name) | .connectionId' <<<"${existing}" | head -n1)"
  if [[ -n "${connection_id}" ]]; then
    detail="$(api_get "/connections/${connection_id}")"
    if [[ "$(jq '(.configurations.streams // []) | length' <<<"${detail}")" -eq 0 ]]; then
      if [[ "$(jq 'length' <<<"${streams}")" -gt 0 ]]; then
        result="$(jq -n --argjson streams "${streams}" '{configurations: {streams: $streams}}')"
        api_patch "/connections/${connection_id}" "${result}" >/dev/null
        success "Updated existing connection streams: ${name} (${connection_id})"
      else
        success "Connection already exists; Airbyte will use its default all-streams catalog: ${name} (${connection_id})"
      fi
    else
      success "Connection already exists: ${name} (${connection_id})"
    fi
    return 0
  fi

  if [[ "$(jq 'length' <<<"${streams}")" -gt 0 ]]; then
    result="$(jq -n --arg name "${name}" --arg source_id "${source_id}" --arg destination_id "${destination_id}" \
      --argjson streams "${streams}" \
      '{name: $name, sourceId: $source_id, destinationId: $destination_id, schedule: {scheduleType: "manual"}, status: "active", namespaceDefinition: "destination", configurations: {streams: $streams}}')"
  else
    result="$(jq -n --arg name "${name}" --arg source_id "${source_id}" --arg destination_id "${destination_id}" \
      '{name: $name, sourceId: $source_id, destinationId: $destination_id, schedule: {scheduleType: "manual"}, status: "active", namespaceDefinition: "destination"}')"
  fi
  result="$(api_post /connections "${result}")"
  connection_id="$(jq -r '.connectionId // empty' <<<"${result}")"
  if [[ -z "${connection_id}" ]]; then
    error "Airbyte did not return a connectionId for '${name}'"
    jq . <<<"${result}" 2>/dev/null || true
    exit 1
  fi
  success "Created connection: ${name} (${connection_id})"
}

discover_streams() {
  local source_id="$1" destination_id="$2"
  local result streams count

  # Public API V1 exposes compatible stream properties through /streams.
  # Fall back to the older discover route for older Airbyte builds.
  if result="$(api_get "/streams?sourceId=${source_id}&destinationId=${destination_id}&ignoreCache=true")"; then
    streams="$(jq -c '[.streams[]?, .data[]? | select(.name != null) | {name: .name, syncMode: "full_refresh_overwrite"}]' <<<"${result}")"
  elif result="$(api_post "/sources/${source_id}/discover" "{}")"; then
    streams="$(jq -c '[.catalog.streams[]?.stream? | select(.name != null) | {name: .name, syncMode: "full_refresh_overwrite"}]' <<<"${result}")"
  else
    warn "Stream discovery endpoints are unavailable; Airbyte will apply its default all-streams catalog"
    streams='[]'
  fi

  count="$(jq 'length' <<<"${streams}")"
  if [[ "${count}" -eq 0 ]]; then
    warn "No explicit streams discovered for source ${source_id}; leaving configurations.streams unset"
    printf '%s\n' "${streams}"
    return 0
  fi
  success "Discovered ${count} stream(s)" >&2
  printf '%s\n' "${streams}"
}

main() {
  printf "\n${BOLD}========================================${NC}\n"
  printf "${BOLD} RAG Airbyte Connector Configuration${NC}\n"
  printf "${BOLD}========================================${NC}\n\n"

  for cmd in curl jq; do
    if ! command -v "${cmd}" &>/dev/null; then
      error "${cmd} CLI not found — install it first"
      exit 1
    fi
  done
  if [[ -z "${AIRBYTE_URL}" && -z "${API_BASE}" ]] && ! command -v oc &>/dev/null; then
    error "oc CLI not found — install it, or provide AIRBYTE_URL/API_BASE"
    exit 1
  fi

  resolve_airbyte_url
  wait_for_api
  setup_workspace

  info "PostgreSQL source discovery requires an existing, seeded database"

  local gdrive_legal_id gdrive_compliance_id s3_source_id postgres_source_id
  local s3_destination_id postgres_destination_id
  gdrive_legal_id="$(create_or_reuse_source "${GDRIVE_LEGAL_NAME}" "${GOOGLE_DRIVE_SOURCE_DEF_ID}" "${GDRIVE_LEGAL_CONFIG_FILE}" GDRIVE_LEGAL_CONFIG_FILE)"
  gdrive_compliance_id="$(create_or_reuse_source "${GDRIVE_COMPLIANCE_NAME}" "${GOOGLE_DRIVE_SOURCE_DEF_ID}" "${GDRIVE_COMPLIANCE_CONFIG_FILE}" GDRIVE_COMPLIANCE_CONFIG_FILE)"
  s3_source_id="$(create_or_reuse_source "${S3_SOURCE_NAME}" "${S3_SOURCE_DEF_ID}" "${S3_SOURCE_CONFIG_FILE}" S3_SOURCE_CONFIG_FILE)"
  postgres_source_id="$(create_or_reuse_source "${POSTGRES_SOURCE_NAME}" "${POSTGRES_SOURCE_DEF_ID}" "${POSTGRES_SOURCE_CONFIG_FILE}" POSTGRES_SOURCE_CONFIG_FILE)"

  s3_destination_id="$(create_or_reuse_destination "${S3_DESTINATION_NAME}" "${S3_DESTINATION_DEF_ID}" "${S3_DESTINATION_CONFIG_FILE}" S3_DESTINATION_CONFIG_FILE)"
  postgres_destination_id="$(create_or_reuse_destination "${POSTGRES_DESTINATION_NAME}" "${POSTGRES_DESTINATION_DEF_ID}" "${POSTGRES_DESTINATION_CONFIG_FILE}" POSTGRES_DESTINATION_CONFIG_FILE)"

  create_or_reuse_connection "RAG - Legal to S3" "${gdrive_legal_id}" "${s3_destination_id}"
  create_or_reuse_connection "RAG - Compliance to S3" "${gdrive_compliance_id}" "${s3_destination_id}"
  create_or_reuse_connection "RAG - Financial Statements to S3" "${s3_source_id}" "${s3_destination_id}"
  create_or_reuse_connection "RAG - SEC PostgreSQL to PostgreSQL" "${postgres_source_id}" "${postgres_destination_id}"

  success "RAG connector configuration is complete"
  info "Connections are manual by default; trigger syncs from the Airbyte UI or API after validating each connector."
}

main "$@"
