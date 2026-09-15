#!/usr/bin/env python3
"""Generate a comprehensive Markdown validation report for Airbyte on OpenShift AI."""

from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import NamedTuple

REPORTS_DIR = Path(__file__).resolve().parent.parent / "reports"
OUTPUT_FILE = REPORTS_DIR / "validation-report.md"

REPORT_FILES: dict[str, str] = {
    "coexistence": "coexistence-check.txt",
    "sync_results": "sync-results.json",
    "chart_verifier": "chart-verifier-results.yaml",
    "certification_summary": "certification-summary.txt",
}


class ClusterInfo(NamedTuple):
    oc_version: str
    cluster_version: str
    rhoai_csv: str


class AcceptanceCriterion(NamedTuple):
    label: str
    status: str  # "PASS", "FAIL", "NOT YET TESTED"
    detail: str


def run_oc_command(args: list[str], timeout: int = 30) -> str:
    """Run an oc CLI command and return its stdout, or an error string on failure."""
    try:
        result = subprocess.run(
            ["oc", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode != 0:
            return f"[ERROR] oc {' '.join(args)}: {result.stderr.strip()}"
        return result.stdout.strip()
    except FileNotFoundError:
        return "[ERROR] oc binary not found in PATH"
    except subprocess.TimeoutExpired:
        return f"[ERROR] oc {' '.join(args)}: timed out after {timeout}s"


def collect_cluster_info() -> ClusterInfo:
    """Gather live cluster metadata via oc commands."""
    oc_version = run_oc_command(["version"])
    cluster_version = run_oc_command(["get", "clusterversion"])
    rhoai_csv = run_oc_command(["get", "csv", "-n", "redhat-ods-applications"])
    return ClusterInfo(
        oc_version=oc_version,
        cluster_version=cluster_version,
        rhoai_csv=rhoai_csv,
    )


def read_file_safe(path: Path) -> str | None:
    """Return file contents or None when the file is missing / unreadable."""
    try:
        return path.read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError):
        return None


def load_report_files() -> dict[str, str | None]:
    """Load each expected report file, returning None for missing ones."""
    return {
        key: read_file_safe(REPORTS_DIR / filename)
        for key, filename in REPORT_FILES.items()
    }


def parse_sync_results(raw: str | None) -> dict[str, object]:
    """Parse sync-results.json into a dict; return empty dict on failure."""
    if raw is None:
        return {}
    try:
        data: object = json.loads(raw)
        if isinstance(data, dict):
            return data
        return {}
    except (json.JSONDecodeError, ValueError):
        return {}


def extract_ocp_version(cluster_version_output: str) -> str:
    """Pull the OCP version string from `oc get clusterversion` output."""
    for line in cluster_version_output.splitlines():
        parts = line.split()
        if parts and parts[0] == "version":
            # header line — skip
            continue
        if len(parts) >= 2 and not parts[0].startswith("["):
            return parts[1]
    return "unknown"


def extract_rhoai_version(csv_output: str) -> str:
    """Pull the RHOAI operator version from `oc get csv` output."""
    for line in csv_output.splitlines():
        lower = line.lower()
        if "rhods-operator" in lower or "rhoai" in lower or "opendatahub" in lower:
            parts = line.split()
            # CSV name usually contains the version, e.g. rhods-operator.2.10.0
            for part in parts:
                if "." in part and any(ch.isdigit() for ch in part):
                    return part
    return "unknown"


def _coexistence_passed(report_text: str) -> bool:
    """Check if the coexistence report indicates all checks passed.

    Looks for structured markers like 'ALL CHECKS PASSED', '[PASS]', and
    'OVERALL: PASS' rather than naive substring matching, which would false-
    positive on descriptions like 'No pods in CrashLoopBackOff, Error, or
    Pending states'.
    """
    upper = report_text.upper()
    if "ALL CHECKS PASSED" in upper:
        return True
    if "OVERALL: PASS" in upper:
        return True
    fail_count = upper.count("[FAIL]")
    pass_count = upper.count("[PASS]")
    if pass_count > 0 and fail_count == 0:
        return True
    return fail_count == 0


def determine_acceptance_criteria(
    reports: dict[str, str | None],
    sync_data: dict[str, object],
) -> list[AcceptanceCriterion]:
    """Evaluate each acceptance criterion based on available report data."""
    criteria: list[AcceptanceCriterion] = []

    # (a) Deploys cleanly on OpenShift
    coex = reports.get("coexistence")
    if coex is None:
        criteria.append(AcceptanceCriterion(
            label="Deploys cleanly on OpenShift",
            status="NOT YET TESTED",
            detail="coexistence-check.txt not found",
        ))
    else:
        if _coexistence_passed(coex):
            criteria.append(AcceptanceCriterion(
                label="Deploys cleanly on OpenShift",
                status="PASS",
                detail="All deployment checks passed",
            ))
        else:
            criteria.append(AcceptanceCriterion(
                label="Deploys cleanly on OpenShift",
                status="FAIL",
                detail="Deployment issues detected — see coexistence-check.txt",
            ))

    # (b) Runs alongside RHOAI without conflict
    if coex is None:
        criteria.append(AcceptanceCriterion(
            label="Runs alongside RHOAI without conflict",
            status="NOT YET TESTED",
            detail="coexistence-check.txt not found",
        ))
    else:
        if _coexistence_passed(coex):
            criteria.append(AcceptanceCriterion(
                label="Runs alongside RHOAI without conflict",
                status="PASS",
                detail="No conflicts detected between Airbyte and RHOAI",
            ))
        else:
            criteria.append(AcceptanceCriterion(
                label="Runs alongside RHOAI without conflict",
                status="FAIL",
                detail="Conflicts or errors found — see coexistence-check.txt",
            ))

    # (c) Data ingestion demonstrated end-to-end
    if not sync_data:
        criteria.append(AcceptanceCriterion(
            label="Data ingestion demonstrated end-to-end",
            status="NOT YET TESTED",
            detail="sync-results.json not found or empty",
        ))
    else:
        status_val = sync_data.get("status", sync_data.get("result", ""))
        status_str = str(status_val).lower()
        if status_str in ("succeeded", "success", "pass", "passed", "completed"):
            criteria.append(AcceptanceCriterion(
                label="Data ingestion demonstrated end-to-end",
                status="PASS",
                detail="End-to-end sync completed successfully",
            ))
        elif status_str in ("failed", "fail", "error"):
            criteria.append(AcceptanceCriterion(
                label="Data ingestion demonstrated end-to-end",
                status="FAIL",
                detail=f"Sync failed — status: {status_val}",
            ))
        else:
            criteria.append(AcceptanceCriterion(
                label="Data ingestion demonstrated end-to-end",
                status="NOT YET TESTED",
                detail=f"Ambiguous sync status: {status_val}",
            ))

    return criteria


def extract_blockers(
    criteria: list[AcceptanceCriterion],
    reports: dict[str, str | None],
) -> list[dict[str, str]]:
    """Identify blockers from failed criteria and report contents."""
    blockers: list[dict[str, str]] = []
    for criterion in criteria:
        if criterion.status == "FAIL":
            blockers.append({
                "criterion": criterion.label,
                "severity": "HIGH",
                "detail": criterion.detail,
                "resolution": "Review the corresponding report file and remediate before re-testing",
            })
    return blockers


def format_status_badge(status: str) -> str:
    """Return a readable status marker for the Markdown table."""
    if status == "PASS":
        return "PASS"
    if status == "FAIL":
        return "FAIL"
    return "NOT YET TESTED"


def build_report(
    cluster: ClusterInfo,
    reports: dict[str, str | None],
    criteria: list[AcceptanceCriterion],
    blockers: list[dict[str, str]],
    sync_data: dict[str, object],
    airbyte_version: str,
    ocp_version: str,
    rhoai_version: str,
) -> str:
    """Assemble the full Markdown report."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    lines: list[str] = []

    def section(heading: str, level: int = 2) -> None:
        lines.append("")
        lines.append(f"{'#' * level} {heading}")
        lines.append("")

    # ── Title ──
    lines.append("# Airbyte on OpenShift AI - Validation Report")
    lines.append("")
    lines.append(f"**Generated:** {now}")
    lines.append("")

    # ── Cluster Info ──
    section("Cluster Information")
    lines.append("### oc version")
    lines.append("")
    lines.append("```")
    lines.append(cluster.oc_version)
    lines.append("```")
    lines.append("")
    lines.append("### Cluster Version")
    lines.append("")
    lines.append("```")
    lines.append(cluster.cluster_version)
    lines.append("```")
    lines.append("")
    lines.append("### RHOAI Operator (CSV)")
    lines.append("")
    lines.append("```")
    lines.append(cluster.rhoai_csv)
    lines.append("```")

    # ── Versions Tested ──
    section("Versions Tested")
    lines.append("| Component | Version |")
    lines.append("|-----------|---------|")
    lines.append(f"| Airbyte | {airbyte_version} |")
    lines.append(f"| OpenShift Container Platform | {ocp_version} |")
    lines.append(f"| Red Hat OpenShift AI (RHOAI) | {rhoai_version} |")

    # ── Compatibility Matrix ──
    section("Compatibility Matrix")
    lines.append("| Airbyte Version | OCP Version | RHOAI Version | Result |")
    lines.append("|-----------------|-------------|---------------|--------|")
    overall = "PASS" if all(c.status == "PASS" for c in criteria) else (
        "FAIL" if any(c.status == "FAIL" for c in criteria) else "INCOMPLETE"
    )
    lines.append(f"| {airbyte_version} | {ocp_version} | {rhoai_version} | {overall} |")

    # ── Acceptance Criteria ──
    section("Acceptance Criteria")
    lines.append("| # | Criterion | Status | Detail |")
    lines.append("|---|-----------|--------|--------|")
    for idx, criterion in enumerate(criteria, start=1):
        badge = format_status_badge(criterion.status)
        lines.append(f"| {idx} | {criterion.label} | {badge} | {criterion.detail} |")

    # ── Blockers ──
    section("Blockers")
    if not blockers:
        lines.append("No blockers identified.")
    else:
        lines.append("| Criterion | Severity | Detail | Resolution Path |")
        lines.append("|-----------|----------|--------|-----------------|")
        for b in blockers:
            lines.append(
                f"| {b['criterion']} | {b['severity']} | {b['detail']} | {b['resolution']} |"
            )

    # ── Certification Readiness ──
    section("Certification Readiness")

    chart_verifier = reports.get("chart_verifier")
    cert_summary = reports.get("certification_summary")

    lines.append("### Chart Verifier Results")
    lines.append("")
    if chart_verifier is None:
        lines.append("**Status:** NOT YET TESTED — chart-verifier-results.yaml not found.")
    else:
        passed = chart_verifier.lower().count("outcome: pass")
        failed = chart_verifier.lower().count("outcome: fail")
        total = passed + failed
        if total == 0:
            lines.append(f"Chart verifier output collected ({len(chart_verifier)} bytes). "
                         "Manual review recommended.")
        else:
            lines.append(f"- **Checks passed:** {passed}/{total}")
            lines.append(f"- **Checks failed:** {failed}/{total}")
            if failed > 0:
                lines.append("")
                lines.append("Failed checks require remediation before certification submission.")

    lines.append("")
    lines.append("### Preflight / Certification Summary")
    lines.append("")
    if cert_summary is None:
        lines.append("**Status:** NOT YET TESTED — certification-summary.txt not found.")
    else:
        lines.append("```")
        lines.append(cert_summary.strip())
        lines.append("```")

    # ── Recommendations for Phase 2 ──
    section("Recommendations for Phase 2")
    recommendations: list[str] = [
        "Run full certification suite (chart-verifier + preflight) and resolve all failures.",
        "Test with multiple Airbyte connector types (database, API, file) to broaden coverage.",
        "Perform load testing with concurrent syncs to validate resource isolation under RHOAI workloads.",
        "Validate upgrade path: Airbyte Helm chart upgrade on a running cluster with active connections.",
        "Document network-policy requirements for multi-tenant OpenShift environments.",
        "Integrate validation scripts into CI/CD pipeline for automated regression testing.",
        "Evaluate Airbyte Operator (if available) as an alternative to Helm-based deployment.",
        "Test with OpenShift GitOps (ArgoCD) for declarative deployment workflows.",
    ]
    for idx, rec in enumerate(recommendations, start=1):
        lines.append(f"{idx}. {rec}")

    # ── Evidence Appendix ──
    section("Evidence Appendix")
    lines.append("| Report File | Path | Status |")
    lines.append("|-------------|------|--------|")
    for key, filename in REPORT_FILES.items():
        path = f"reports/{filename}"
        status = "Present" if reports.get(key) is not None else "Missing"
        lines.append(f"| {filename} | `{path}` | {status} |")
    lines.append(f"| validation-report.md | `reports/validation-report.md` | Generated |")

    lines.append("")
    lines.append("---")
    lines.append(f"*Report generated by `scripts/07-generate-report.py` on {now}*")
    lines.append("")

    return "\n".join(lines)


def detect_airbyte_version() -> str:
    """Attempt to detect the Airbyte version from the cluster or Helm release."""
    output = run_oc_command(
        ["get", "configmap", "-n", "airbyte-validation", "-o", "jsonpath={.items[*].metadata.name}"],
        timeout=15,
    )
    if output.startswith("[ERROR]"):
        # Try helm
        try:
            result = subprocess.run(
                ["helm", "list", "-n", "airbyte-validation", "-o", "json"],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if result.returncode == 0:
                releases = json.loads(result.stdout)
                for release in releases:
                    chart = release.get("chart", "")
                    if "airbyte" in chart.lower():
                        return chart
        except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError):
            pass
        return "unknown"
    return "detected (see cluster info)"


def main() -> None:
    """Entry point: collect data, evaluate criteria, write report."""
    print("Collecting cluster information...")
    cluster = collect_cluster_info()

    print("Loading report files...")
    reports = load_report_files()

    print("Parsing sync results...")
    sync_data = parse_sync_results(reports.get("sync_results"))

    print("Evaluating acceptance criteria...")
    criteria = determine_acceptance_criteria(reports, sync_data)

    print("Checking for blockers...")
    blockers = extract_blockers(criteria, reports)

    # Extract versions
    ocp_version = extract_ocp_version(cluster.cluster_version)
    rhoai_version = extract_rhoai_version(cluster.rhoai_csv)
    airbyte_version = detect_airbyte_version()

    print("Generating report...")
    report = build_report(
        cluster=cluster,
        reports=reports,
        criteria=criteria,
        blockers=blockers,
        sync_data=sync_data,
        airbyte_version=airbyte_version,
        ocp_version=ocp_version,
        rhoai_version=rhoai_version,
    )

    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_FILE.write_text(report, encoding="utf-8")
    print(f"Report written to: {OUTPUT_FILE}")

    # Summary to stdout
    passed = sum(1 for c in criteria if c.status == "PASS")
    failed = sum(1 for c in criteria if c.status == "FAIL")
    untested = sum(1 for c in criteria if c.status == "NOT YET TESTED")
    print(f"\nResults: {passed} passed, {failed} failed, {untested} not yet tested")
    if blockers:
        print(f"Blockers: {len(blockers)}")
    else:
        print("No blockers identified.")

    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
