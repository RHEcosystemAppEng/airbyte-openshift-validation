#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# 06-certification-checks.sh
# Runs Red Hat certification tooling against the Airbyte deployment:
#   - chart-verifier  (Helm chart compliance)
#   - preflight       (container image compliance)
# ---------------------------------------------------------------------------

# -- Colors -----------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# -- Configuration ----------------------------------------------------------
NAMESPACE="${AIRBYTE_NAMESPACE:-airbyte-validation}"
CHART_URL="${AIRBYTE_CHART_URL:-https://airbytehq.github.io/charts/airbyte-2.1.1.tgz}"
OPENSHIFT_VERSION="${OPENSHIFT_VERSION:-4.21}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORTS_DIR="${SCRIPT_DIR}/../reports"
DOCKER_CONFIG="${DOCKER_CONFIG:-${HOME}/.docker/config.json}"

PASSED=0
FAILED=0
SKIPPED=0
SUMMARY_LINES=()

# -- Helpers ----------------------------------------------------------------
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[PASS]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
header(){ echo -e "\n${BOLD}=== $* ===${NC}"; }

add_summary() {
    SUMMARY_LINES+=("$1")
}

ensure_reports_dir() {
    mkdir -p "${REPORTS_DIR}"
}

# Detect whether we are on macOS and resolve the podman machine socket.
detect_container_socket() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS: podman runs inside a VM; the socket is exposed via podman machine
        local machine_socket
        machine_socket="$(podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)"
        if [[ -z "${machine_socket}" ]]; then
            # Fallback: default path used by podman 4+
            machine_socket="${HOME}/.local/share/containers/podman/machine/podman.sock"
        fi
        echo "${machine_socket}"
    else
        # Linux: use the standard podman socket or docker socket
        if [[ -S "/run/podman/podman.sock" ]]; then
            echo "/run/podman/podman.sock"
        elif [[ -S "/var/run/docker.sock" ]]; then
            echo "/var/run/docker.sock"
        else
            echo ""
        fi
    fi
}

# Sanitize an image reference into a safe filename fragment.
# e.g. docker.io/airbyte/source-postgres:0.6.4 -> docker.io_airbyte_source-postgres_0.6.4
sanitize_image_name() {
    echo "$1" | tr '/:@' '___'
}

# ---------------------------------------------------------------------------
# Step 1 - Chart Verifier
# ---------------------------------------------------------------------------
run_chart_verifier() {
    header "Helm Chart Verification (chart-verifier)"

    local output_file="${REPORTS_DIR}/chart-verifier-results.yaml"

    info "Verifying chart: ${CHART_URL}"
    info "OpenShift version: ${OPENSHIFT_VERSION}"
    info "Output: ${output_file}"

    if ! command -v podman &>/dev/null; then
        fail "podman is not installed -- cannot run chart-verifier"
        add_summary "chart-verifier: SKIPPED (podman not found)"
        (( SKIPPED++ ))
        return
    fi

    if podman run --rm \
        quay.io/redhat-certification/chart-verifier:latest \
        verify \
        --openshift-version "${OPENSHIFT_VERSION}" \
        "${CHART_URL}" \
        -o yaml > "${output_file}" 2>&1; then

        # Parse pass/fail from the YAML output
        local total passed failed_count
        total=$(grep -c 'outcome:' "${output_file}" 2>/dev/null || echo 0)
        passed=$(grep -c 'outcome: PASS' "${output_file}" 2>/dev/null || echo 0)
        failed_count=$(( total - passed ))

        if [[ "${failed_count}" -eq 0 && "${total}" -gt 0 ]]; then
            ok "Chart verification passed (${passed}/${total} checks)"
            add_summary "chart-verifier: PASSED (${passed}/${total} checks)"
            (( PASSED++ ))
        else
            fail "Chart verification had failures (${passed}/${total} passed)"
            add_summary "chart-verifier: FAILED (${passed}/${total} passed)"
            (( FAILED++ ))
        fi
    else
        fail "chart-verifier exited with an error -- see ${output_file}"
        add_summary "chart-verifier: FAILED (exit error)"
        (( FAILED++ ))
    fi

    info "Full report: ${output_file}"
}

# ---------------------------------------------------------------------------
# Step 2 - Collect unique container images from the deployment
# ---------------------------------------------------------------------------
collect_images() {
    header "Collecting Container Images from Namespace '${NAMESPACE}'"

    if ! command -v oc &>/dev/null; then
        fail "oc CLI not found -- cannot query cluster"
        add_summary "image-collection: SKIPPED (oc not found)"
        (( SKIPPED++ ))
        return 1
    fi

    local raw_images
    raw_images=$(oc get pods -n "${NAMESPACE}" \
        -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null || true)

    if [[ -z "${raw_images}" ]]; then
        warn "No pods found in namespace '${NAMESPACE}' -- is Airbyte deployed?"
        add_summary "image-collection: SKIPPED (no pods)"
        (( SKIPPED++ ))
        return 1
    fi

    # De-duplicate and sort
    UNIQUE_IMAGES=$(echo "${raw_images}" | sort -u | grep -v '^$')
    local count
    count=$(echo "${UNIQUE_IMAGES}" | wc -l | tr -d ' ')

    info "Found ${count} unique container image(s):"
    echo "${UNIQUE_IMAGES}" | while read -r img; do
        echo "    ${img}"
    done

    add_summary "image-collection: ${count} unique images found"
    return 0
}

# ---------------------------------------------------------------------------
# Step 3 - Run preflight against each container image
# ---------------------------------------------------------------------------
run_preflight_checks() {
    header "Preflight Container Checks"

    local socket
    socket=$(detect_container_socket)

    local is_macos=false
    [[ "$(uname -s)" == "Darwin" ]] && is_macos=true

    if ! command -v podman &>/dev/null; then
        fail "podman is not installed -- cannot run preflight"
        add_summary "preflight: SKIPPED (podman not found)"
        (( SKIPPED++ ))
        return
    fi

    if [[ -z "${socket}" ]]; then
        warn "No container socket detected"
        if ${is_macos}; then
            warn "Known limitation: on macOS the preflight container needs access"
            warn "to a container runtime socket. Ensure 'podman machine' is running."
            warn "For reliable results, run this script on a Linux host."
            add_summary "preflight: SKIPPED (no socket on macOS)"
            (( SKIPPED++ ))
            return
        fi
    fi

    local img_passed=0
    local img_failed=0
    local img_skipped=0

    while IFS= read -r image; do
        [[ -z "${image}" ]] && continue

        local safe_name
        safe_name=$(sanitize_image_name "${image}")
        local report_file="${REPORTS_DIR}/preflight-${safe_name}.json"

        info "Checking image: ${image}"

        # Build the podman run command
        local socket_mount=""
        if [[ -n "${socket}" ]]; then
            socket_mount="-v ${socket}:/var/run/docker.sock"
        fi

        local docker_cfg_mount=""
        if [[ -f "${DOCKER_CONFIG}" ]]; then
            docker_cfg_mount="-v ${DOCKER_CONFIG}:/etc/preflight/docker-config.json:ro"
        fi

        # shellcheck disable=SC2086
        if podman run --rm --privileged \
            ${socket_mount} \
            ${docker_cfg_mount} \
            quay.io/opdev/preflight:stable \
            check container "${image}" \
            ${docker_cfg_mount:+--docker-config=/etc/preflight/docker-config.json} \
            > "${report_file}" 2>&1; then

            # Check the JSON for pass/fail
            if command -v jq &>/dev/null && [[ -f "${report_file}" ]]; then
                local result
                result=$(jq -r '.passed // false' "${report_file}" 2>/dev/null || echo "unknown")
                if [[ "${result}" == "true" ]]; then
                    ok "PASSED: ${image}"
                    (( img_passed++ ))
                else
                    fail "FAILED: ${image} (see ${report_file})"
                    (( img_failed++ ))
                fi
            else
                ok "Completed: ${image} (manual review needed)"
                (( img_passed++ ))
            fi
        else
            if ${is_macos}; then
                warn "SKIPPED: ${image} (preflight failed -- macOS limitation)"
                warn "  Preflight container checks require a Linux container runtime."
                warn "  Re-run this script on a Linux host for accurate results."
                (( img_skipped++ ))
            else
                fail "ERROR: ${image} (see ${report_file})"
                (( img_failed++ ))
            fi
        fi
    done <<< "${UNIQUE_IMAGES}"

    info "Preflight results: ${img_passed} passed, ${img_failed} failed, ${img_skipped} skipped"
    add_summary "preflight: ${img_passed} passed, ${img_failed} failed, ${img_skipped} skipped"

    PASSED=$(( PASSED + img_passed ))
    FAILED=$(( FAILED + img_failed ))
    SKIPPED=$(( SKIPPED + img_skipped ))
}

# ---------------------------------------------------------------------------
# Step 4 - Write summary report
# ---------------------------------------------------------------------------
write_summary() {
    header "Certification Summary"

    local summary_file="${REPORTS_DIR}/certification-summary.txt"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    {
        echo "============================================================"
        echo "  Red Hat Certification Check Summary"
        echo "  Generated: ${timestamp}"
        echo "  Namespace: ${NAMESPACE}"
        echo "  Chart URL: ${CHART_URL}"
        echo "  OpenShift: ${OPENSHIFT_VERSION}"
        echo "============================================================"
        echo ""
        echo "Results:"
        echo "  Passed:  ${PASSED}"
        echo "  Failed:  ${FAILED}"
        echo "  Skipped: ${SKIPPED}"
        echo ""
        echo "Details:"
        for line in "${SUMMARY_LINES[@]}"; do
            echo "  - ${line}"
        done
        echo ""
        echo "Reports directory: ${REPORTS_DIR}/"
        echo ""

        if [[ "${FAILED}" -gt 0 ]]; then
            echo "OVERALL: FAIL"
            echo ""
            echo "Review the individual report files for remediation guidance."
        elif [[ "${SKIPPED}" -gt 0 ]]; then
            echo "OVERALL: INCOMPLETE (some checks were skipped)"
            echo ""
            echo "Re-run skipped checks on a supported platform for full results."
        else
            echo "OVERALL: PASS"
        fi

        echo ""
        echo "============================================================"
        echo "Notes:"
        echo "  - chart-verifier report: ${REPORTS_DIR}/chart-verifier-results.yaml"
        echo "  - preflight reports:     ${REPORTS_DIR}/preflight-*.json"
        echo "  - macOS limitation: preflight container checks require a Linux"
        echo "    container runtime with direct socket access. For production"
        echo "    certification, run on a RHEL or Fedora host."
        echo "============================================================"
    } > "${summary_file}"

    echo ""
    cat "${summary_file}"
    echo ""

    if [[ "${FAILED}" -gt 0 ]]; then
        fail "Certification checks completed with failures"
    elif [[ "${SKIPPED}" -gt 0 ]]; then
        warn "Certification checks completed with skipped items"
    else
        ok "All certification checks passed"
    fi

    info "Summary saved to: ${summary_file}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo -e "${BOLD}Red Hat Certification Checks for Airbyte${NC}"
    echo -e "Running at $(date -u '+%Y-%m-%d %H:%M:%S UTC')\n"

    ensure_reports_dir

    # Chart verification
    run_chart_verifier

    # Collect images and run preflight (only if images found)
    UNIQUE_IMAGES=""
    if collect_images; then
        run_preflight_checks
    fi

    # Summary
    write_summary
}

main "$@"
