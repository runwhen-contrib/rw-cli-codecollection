#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# test-live.sh -- the LIVE tier for gcp-apigee-proxy-health.
#
# Runs every check script against the SHARED test org and asserts on each
# script's OWN outputs. Correctness of the check logic is covered by the offline
# tier (offline/run.sh), which needs no credentials; this tier exists to confirm
# the scripts behave the same way against real API responses, real pagination
# and real error bodies -- the three things canned fixtures cannot reproduce.
#
# Requires the fixtures from `task build-infra` and active credentials (see
# terraform/tf.secret). For a credential-free run of the same logic:
#   task test-offline
#
# ONE SHARED WORKING DIRECTORY, IN ORDER.
#
# Unlike the sibling governance bundle, whose checks are independent, these
# scripts share a discovery cache: discover_proxies.sh writes
# apigee_deployments.json, apigee_proxies.json and apigee_topology.json, and
# every check afterwards reads them instead of re-fetching. Running each script
# in its own directory would silently bypass that cache and exercise a code path
# production never takes -- and would multiply the API calls by nine. Running
# them in sequence in one directory is what the runbook does.
#
# Exits non-zero if any assertion fails, and keeps going after the first so one
# run shows the whole blast radius.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${HERE}/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apigee-proxy-live-XXXXXX")"

: "${APIGEE_ORG:=${TF_VAR_org_id:-}}"
: "${GCP_PROJECT_ID:=${TF_VAR_project_id:-}}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID (or TF_VAR_project_id)}"
# APIGEE_ORG is deliberately allowed to be empty: the empty value exercises the
# org auto-discovery path, which is what the generation rule relies on.
APIGEE_ORG="${APIGEE_ORG#organizations/}"
export APIGEE_ORG GCP_PROJECT_ID
export PROXIES="${PROXIES:-All}"
export ENVIRONMENTS="${ENVIRONMENTS:-All}"
export ANALYTICS_WINDOW_MIN="${ANALYTICS_WINDOW_MIN:-60}"
export LATENCY_MS_THRESHOLD="${LATENCY_MS_THRESHOLD:-1000}"
export OVERHEAD_MS_THRESHOLD="${OVERHEAD_MS_THRESHOLD:-100}"
export POLICY_ERROR_THRESHOLD="${POLICY_ERROR_THRESHOLD:-5}"
export TARGET_ERROR_THRESHOLD="${TARGET_ERROR_THRESHOLD:-5}"
export AUTH_ERROR_RATE_THRESHOLD="${AUTH_ERROR_RATE_THRESHOLD:-5}"
export RATE_LIMIT_ERROR_THRESHOLD="${RATE_LIMIT_ERROR_THRESHOLD:-5}"
export REVISION_ACCUMULATION_THRESHOLD="${REVISION_ACCUMULATION_THRESHOLD:-10}"

# script|issues_file
#
# Named per script rather than globbed. Validating "the first *_issues.json in
# the directory" would re-check an earlier script's output once several exist,
# so a check that stopped producing anything would still look green.
#
# discover_proxies.sh is FIRST and is not optional: everything below reads the
# cache it writes.
CASES="
discover_proxies.sh|apigee_discovery_issues.json
check_deployment_state.sh|deployment_state_issues.json
check_environment_coverage.sh|environment_coverage_issues.json
check_failed_deployments.sh|failed_deployments_issues.json
check_failed_operations.sh|failed_operations_issues.json
check_revision_accumulation.sh|revision_accumulation_issues.json
check_revision_drift.sh|revision_drift_issues.json
analyze_http_error_rates.sh|http_error_rate_issues.json
analyze_error_split.sh|error_split_issues.json
analyze_latency_split.sh|latency_split_issues.json
"

failures=0
note_failure() { echo "    ✗ $1"; failures=$((failures + 1)); }

cd "${WORK_DIR}" || exit 1
echo "=== Apigee Proxy Health -- live tier ==="
echo "Project: ${GCP_PROJECT_ID}   org: ${APIGEE_ORG:-(auto-discover)}"
echo "Working directory: ${WORK_DIR}"
echo

while IFS='|' read -r script issues_file; do
  [ -z "${script}" ] && continue
  echo "==> ${script}"

  bash "${BUNDLE_DIR}/${script}" > "${WORK_DIR}/${script%.sh}.stdout" 2> "${WORK_DIR}/${script%.sh}.stderr"
  rc=$?

  # Check scripts REPORT problems; they do not fail on them. A non-zero exit is
  # the script itself breaking, which is a different and worse thing.
  if [ "${rc}" -ne 0 ]; then
    note_failure "${script} exited ${rc} (expected 0; check scripts report problems, they do not fail)"
    echo "        stderr: $(head -c 300 "${WORK_DIR}/${script%.sh}.stderr")"
    continue
  fi

  if [ ! -f "${issues_file}" ]; then
    note_failure "${script} did not produce ${issues_file}"
    continue
  fi
  if ! jq -e 'type == "array"' "${issues_file}" >/dev/null 2>&1; then
    note_failure "${issues_file} is not a valid JSON array"
    echo "        head: $(head -c 300 "${issues_file}")"
    continue
  fi

  # Every issue must carry the fields the runbook indexes, or Add Issue throws
  # at runtime -- which surfaces as a broken task, not as a reported problem.
  missing="$(jq -r '[.[] | select(
      has("title") and has("details") and has("severity") and
      has("next_steps") and has("expected") and has("actual") | not
    )] | length' "${issues_file}")"
  if [ "${missing}" != "0" ]; then
    note_failure "${issues_file} has ${missing} issue(s) missing required runbook fields"
  fi

  echo "    ✓ ${issues_file}: valid array, $(jq 'length' "${issues_file}") issue(s)"

  # After discovery, prove the inventory was actually established. Without this
  # the whole run can pass having judged nothing: a 403 turns every list into
  # [], and "no proxies found" reads identically to "no proxies are broken".
  if [ "${script}" = "discover_proxies.sh" ]; then
    status="$(jq -r '.status // "missing"' apigee_topology.json 2>/dev/null || echo "missing")"
    if [ "${status}" != "ok" ]; then
      note_failure "discovery reported status='${status}'; every check below judges an empty inventory"
      echo "      reason: $(jq -r '.reason // "(none)"' apigee_topology.json 2>/dev/null)"
    else
      echo "    ✓ topology status=ok, $(jq '.proxies | length' apigee_proxies.json 2>/dev/null || echo 0) proxy/proxies discovered"
    fi
  fi
done <<EOF
$(printf '%s\n' "${CASES}")
EOF

# The API-error ledger is the bundle's guard against scoring an inaccessible org
# as healthy, so a live run that logged errors is not a clean live run.
if [ -f apigee_api_errors.json ]; then
  err_count="$(jq 'length' apigee_api_errors.json 2>/dev/null || echo 0)"
  if [ "${err_count}" != "0" ]; then
    note_failure "${err_count} API error(s) recorded during the run; the results are not trustworthy"
    jq -r '.[] | "      HTTP \(.code) on \(.path)"' apigee_api_errors.json 2>/dev/null | head -10
  else
    echo "    ✓ no API errors recorded"
  fi
fi

echo
if [ "${failures}" -gt 0 ]; then
  echo "Live tier FAILED: ${failures} assertion(s) failed."
  echo "Artifacts preserved at: ${WORK_DIR}"
  exit 1
fi

echo "All checks produced valid, readable output against org ${APIGEE_ORG:-(auto-discovered)}."
if [ "${KEEP_ARTIFACTS:-0}" = "1" ]; then
  echo "Artifacts preserved at: ${WORK_DIR}"
else
  rm -rf "${WORK_DIR}"
fi
