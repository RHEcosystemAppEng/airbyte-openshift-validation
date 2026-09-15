#!/usr/bin/env bash
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

NAMESPACE="airbyte-validation"
DEPLOYMENT="postgresql"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../manifests/postgresql.yaml"
SEED_SQL="${SCRIPT_DIR}/../data/seed.sql"

# --- Helper functions ---
info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
step()    { printf "\n${BOLD}${CYAN}==>${NC} ${BOLD}%s${NC}\n" "$*"; }

# --- Preflight checks ---
step "Preflight checks"

if ! command -v oc &>/dev/null; then
    error "oc CLI not found -- install the OpenShift CLI first"
    exit 1
fi

if ! oc whoami &>/dev/null; then
    error "Not logged in to OpenShift -- run 'oc login' first"
    exit 1
fi

if [[ ! -f "${MANIFEST}" ]]; then
    error "PostgreSQL manifest not found at ${MANIFEST}"
    exit 1
fi

if [[ ! -f "${SEED_SQL}" ]]; then
    error "Seed SQL file not found at ${SEED_SQL}"
    exit 1
fi

success "oc CLI available, logged in as $(oc whoami)"

# --- Deploy PostgreSQL ---
step "Deploying PostgreSQL into ${NAMESPACE}"

oc apply -f "${MANIFEST}"
success "PostgreSQL manifest applied"

# --- Wait for pod readiness ---
step "Waiting for PostgreSQL pod to become ready"

info "Waiting for deployment rollout (timeout: 180s)..."
if ! oc rollout status "deployment/${DEPLOYMENT}" -n "${NAMESPACE}" --timeout=180s; then
    error "PostgreSQL deployment did not become ready within 180s"
    oc get pods -n "${NAMESPACE}" -l app=postgresql
    exit 1
fi

POD_NAME=$(oc get pods -n "${NAMESPACE}" -l app=postgresql -o jsonpath='{.items[0].metadata.name}' --field-selector=status.phase=Running)

if [[ -z "${POD_NAME}" ]]; then
    error "Could not find a running PostgreSQL pod"
    exit 1
fi

success "PostgreSQL pod ready: ${POD_NAME}"

# --- Seed the database ---
step "Seeding database with sample data"

info "Copying seed file into pod..."
oc cp "${SEED_SQL}" "${NAMESPACE}/${POD_NAME}:/tmp/seed.sql"

info "Executing seed SQL..."
oc exec "${POD_NAME}" -n "${NAMESPACE}" -- \
    bash -c 'psql -U "${POSTGRESQL_USER}" -d "${POSTGRESQL_DATABASE}" -f /tmp/seed.sql'

success "Database seeded"

# --- Verify seeded data ---
step "Verifying seeded data"

TABLES=$(oc exec "${POD_NAME}" -n "${NAMESPACE}" -- \
    bash -c 'psql -U "${POSTGRESQL_USER}" -d "${POSTGRESQL_DATABASE}" -t -A -c "
        SELECT tablename FROM pg_tables WHERE schemaname = '\''public'\'' ORDER BY tablename;
    "')

if [[ -z "${TABLES}" ]]; then
    warn "No tables found in public schema -- seed may have used a different schema"
else
    printf "\n${BOLD}%-30s %s${NC}\n" "TABLE" "ROW COUNT"
    printf "%-30s %s\n" "------------------------------" "----------"

    TOTAL=0
    while IFS= read -r TABLE; do
        [[ -z "${TABLE}" ]] && continue
        COUNT=$(oc exec "${POD_NAME}" -n "${NAMESPACE}" -- \
            bash -c "psql -U \"\${POSTGRESQL_USER}\" -d \"\${POSTGRESQL_DATABASE}\" -t -A -c \"SELECT count(*) FROM ${TABLE};\"")
        printf "%-30s %s\n" "${TABLE}" "${COUNT}"
        TOTAL=$((TOTAL + COUNT))
    done <<< "${TABLES}"

    printf "%-30s %s\n" "------------------------------" "----------"
    printf "${BOLD}%-30s %s${NC}\n" "TOTAL" "${TOTAL}"

    if [[ "${TOTAL}" -eq 0 ]]; then
        warn "All tables are empty -- check seed.sql content"
    else
        success "Verified ${TOTAL} total rows across tables"
    fi
fi

# --- Print connection details ---
step "PostgreSQL connection details for Airbyte"

SVC_HOST="postgresql.${NAMESPACE}.svc.cluster.local"

printf "\n"
printf "${BOLD}  %-16s${NC} %s\n" "Host:" "${SVC_HOST}"
printf "${BOLD}  %-16s${NC} %s\n" "Port:" "5432"
printf "${BOLD}  %-16s${NC} %s\n" "Database:" "sample_data"
printf "${BOLD}  %-16s${NC} %s\n" "Username:" "airbyte_test"
printf "${BOLD}  %-16s${NC} %s\n" "Password:" "testpass123"
printf "${BOLD}  %-16s${NC} %s\n" "JDBC URL:" "jdbc:postgresql://${SVC_HOST}:5432/sample_data"
printf "\n"

info "Use these values when configuring a PostgreSQL source in Airbyte."
info "The service is accessible only within the cluster via ClusterIP."

printf "\n"
success "Data source deployment complete"
