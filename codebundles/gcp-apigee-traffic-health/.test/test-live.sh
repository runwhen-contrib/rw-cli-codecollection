#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# test-live.sh -- the LIVE tier for gcp-apigee-traffic-health.
#
# Runs every check script against the SHARED test org and the project's real
# Cloud Monitoring data, and asserts on each script's OWN outputs. Correctness
# of the check logic is covered by the offline tier (offline/run.sh), which
# needs no credentials; this tier exists to confirm the scripts behave the same
# way against real timeSeries responses -- notably that an empty result set is
# reported as "no data for this window", not as a clean score.
#
# Requires active credentials (see terraform/tf.secret). For a credential-free
# run of the same logic:
#   task test-offline
#
# ONE SHARED WORKING DIRECTORY, IN ORDER.
#
# discover_metrics_scope.sh writes apigee_scope.json, and every check afterwards
# reads it to learn which org and proxies to query. Running each script in its
# own directory would leave the scope absent and exercise a fallback path the
# runbook never takes.
#
# NOTE ON EMPTY WINDOWS. This bundle reads metrics for proxies the sibling
# bundles deploy, and a freshly built fixture org has served no traffic. Zero
# issues is therefore the EXPECTED result here, and is not evidence the checks
# work -- what this tier proves is that the scripts run, emit well-formed
# artifacts, and say plainly that they had no data. The offline tier is what
# proves they detect a breach when there is one.
#
# Exits non-zero if any assertion fails, and keeps going after the first so one
# run shows the whole blast radius.
# -----------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "${HERE}/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/apigee-traffic-live-XXXXXX")"

: "${APIGEE_ORG:=${TF_VAR_org_id:-}}"
: "${GCP_PROJECT_ID:=${TF_VAR_project_id:-}}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID (or TF_VAR_project_id)}"
# APIGEE_ORG is deliberately allowed to be empty: the empty value exercises the
# scope-discovery path, which is what the generation rule relies on.
APIGEE_ORG="${APIGEE_ORG#organizations/}"
export APIGEE_ORG GCP_PROJECT_ID
export ERROR_RATE_THRESHOLD="${ERROR_RATE_THRESHOLD:-5}"
export LATENCY_MS_THRESHOLD="${LATENCY_MS_THRESHOLD:-1000}"
export METRIC_WINDOW_MIN="${METRIC_WINDOW_MIN:-60}"
export THROUGHPUT_DEVIATION_PCT="${THROUGHPUT_DEVIATION_PCT:-50}"

# script|issues_file|report_file  ("-" where a script owns no report)
#
# Named per script rather than globbed: validating "the first *_issues.json in
# the directory" would re-check an earlier script's output once several exist,
# so a check that stopped producing anything would still look green.
#
# discover_metrics_scope.sh is FIRST and is not optional: everything below reads
# the apigee_scope.json it writes.
CASES="
discover_metrics_scope.sh|discovery_issues.json|-
check_error_rates.sh|error_rate_issues.json|error_rate_report.json
check_latency.sh|latency_issues.json|latency_report.json
check_throughput.sh|throughput_issues.json|throughput_report.json
check_target_performance.sh|target_performance_issues.json|target_report.json
"

failures=0
note_failure() { echo "    ✗ $1"; failures=$((failures + 1)); }

cd "${WORK_DIR}" || exit 1
echo "=== Apigee Traffic Health -- live tier ==="
echo "Project: ${GCP_PROJECT_ID}   org: ${APIGEE_ORG:-(auto-discover)}   window: ${METRIC_WINDOW_MIN}m"
echo "Working directory: ${WORK_DIR}"
echo

while IFS='|' read -r script issues_file report_file; do
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

  if [ "${report_file}" != "-" ]; then
    # The report is what the runbook renders; a check that emits issues but no
    # report leaves the task with nothing to show.
    if [ ! -f "${report_file}" ]; then
      note_failure "${script} did not produce ${report_file}"
    elif ! jq -e 'type == "array" or type == "object"' "${report_file}" >/dev/null 2>&1; then
      note_failure "${report_file} is not valid JSON"
    fi
  fi

  echo "    ✓ ${issues_file}: valid array, $(jq 'length' "${issues_file}") issue(s)"

  # After scope discovery, prove the org was actually resolved. Without this the
  # whole run can pass having queried nothing: an unresolved org means every
  # metric filter matches no series, and "no breach" reads identically to
  # "no query was made".
  if [ "${script}" = "discover_metrics_scope.sh" ]; then
    if [ ! -f apigee_scope.json ]; then
      note_failure "discovery did not write apigee_scope.json; every check below queries an empty scope"
    else
      resolved="$(jq -r '.organization // ""' apigee_scope.json 2>/dev/null)"
      if [ -z "${resolved}" ]; then
        note_failure "discovery resolved no organization; every check below queries an empty scope"
      else
        echo "    ✓ scope resolved: org=${resolved}, $(jq '.proxies | length' apigee_scope.json 2>/dev/null || echo 0) proxy/proxies"
      fi
    fi
  fi
done <<EOF
$(printf '%s\n' "${CASES}")
EOF

echo
if [ "${failures}" -gt 0 ]; then
  echo "Live tier FAILED: ${failures} assertion(s) failed."
  echo "Artifacts preserved at: ${WORK_DIR}"
  exit 1
fi

echo "All checks produced valid, readable output against org ${APIGEE_ORG:-(auto-discovered)}."
echo "Zero issues is expected on a fixture org that has served no traffic; see the"
echo "header for why that is not evidence the checks detect a breach."
if [ "${KEEP_ARTIFACTS:-0}" = "1" ]; then
  echo "Artifacts preserved at: ${WORK_DIR}"
else
  rm -rf "${WORK_DIR}"
fi
