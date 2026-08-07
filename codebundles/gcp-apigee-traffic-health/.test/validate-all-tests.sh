#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# validate-all-tests.sh -- Deterministic mock-based validation for
# gcp-apigee-traffic-health.
#
# Runs each bundle script against the mock fixtures under ./mock under the 3
# design-spec test scenarios (healthy, high_error, latency_target) and asserts
# the expected issue counts are produced. This proves the threshold logic is
# deterministic without requiring real Apigee/Cloud Monitoring access.
#
# Usage: ./validate-all-tests.sh
# Exit code 0 on success, 1 on any assertion failure.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MOCK_BASE="$SCRIPT_DIR/mock"
WORK_BASE="$(mktemp -d)"
trap 'rm -rf "$WORK_BASE"' EXIT

export ERROR_RATE_THRESHOLD="${ERROR_RATE_THRESHOLD:-5}"
export LATENCY_MS_THRESHOLD="${LATENCY_MS_THRESHOLD:-500}"
export METRIC_WINDOW_MIN="${METRIC_WINDOW_MIN:-60}"
export APIGEE_ORG="mock-org"
export GCP_PROJECT_ID="mock-project"

CHECK_SCRIPTS=(
  "discover_metrics_scope.sh:scope.json"
  "check_error_rates.sh:error.json"
  "check_latency.sh:latency.json"
  "check_throughput.sh:throughput.json"
  "check_target_performance.sh:target.json"
)

ISSUE_FILE_MAP=(
  "discover_metrics_scope.sh:discovery_issues.json"
  "check_error_rates.sh:error_rate_issues.json"
  "check_latency.sh:latency_issues.json"
  "check_throughput.sh:throughput_issues.json"
  "check_target_performance.sh:target_performance_issues.json"
)

# Expected number of issues per script per scenario.
declare -A EXPECTED
EXPECTED["healthy:discover_metrics_scope.sh"]=0
EXPECTED["healthy:check_error_rates.sh"]=0
EXPECTED["healthy:check_latency.sh"]=0
EXPECTED["healthy:check_throughput.sh"]=0
EXPECTED["healthy:check_target_performance.sh"]=0
EXPECTED["healthy:generate_traffic_summary.sh"]=0

EXPECTED["high_error:discover_metrics_scope.sh"]=0
EXPECTED["high_error:check_error_rates.sh"]=1
EXPECTED["high_error:check_latency.sh"]=0
EXPECTED["high_error:check_throughput.sh"]=0
EXPECTED["high_error:check_target_performance.sh"]=0
EXPECTED["high_error:generate_traffic_summary.sh"]=1

EXPECTED["latency_target:discover_metrics_scope.sh"]=0
EXPECTED["latency_target:check_error_rates.sh"]=0
EXPECTED["latency_target:check_latency.sh"]=1
EXPECTED["latency_target:check_throughput.sh"]=0
EXPECTED["latency_target:check_target_performance.sh"]=1
EXPECTED["latency_target:generate_traffic_summary.sh"]=1

failures=0
runs=0

for scenario in healthy high_error latency_target; do
  workdir="$WORK_BASE/$scenario"
  mkdir -p "$workdir"
  echo ""
  echo "===== Scenario: $scenario ====="

  # Run each check script inside a clean work dir with mock data so that all
  # output/report/issue files land in the same work dir for the summary task.
  for entry in "${CHECK_SCRIPTS[@]}"; do
    script="${entry%%:*}"
    mockfile="${entry##*:}"
    ( cd "$workdir" && MOCK_DATA_FILE="$MOCK_BASE/$scenario/$mockfile" \
        "$BUNDLE_DIR/$script" >/dev/null 2>&1 ) || true
  done

  # Run the summary in the work dir so it can read the sibling output files.
  ( cd "$workdir" && MOCK_DATA_FILE= "$BUNDLE_DIR/generate_traffic_summary.sh" >/dev/null 2>&1 ) || true

  # Assert issue counts.
  for entry in "${ISSUE_FILE_MAP[@]}"; do
    script="${entry%%:*}"
    issuefile="${entry##*:}"
    expected="${EXPECTED["$scenario:$script"]:-0}"
    actual=0
    if [ -f "$workdir/$issuefile" ]; then
      actual=$(jq 'length' "$workdir/$issuefile" 2>/dev/null || echo 0)
    fi
    runs=$(( runs + 1 ))
    if [ "$actual" != "$expected" ]; then
      echo "  FAIL [$scenario/$script]: expected $expected issue(s), got $actual"
      failures=$(( failures + 1 ))
    else
      echo "  PASS [$scenario/$script]: $actual issue(s)"
    fi
  done

  # Assert summary issue count.
  expected="${EXPECTED["$scenario:generate_traffic_summary.sh"]:-0}"
  actual=0
  if [ -f "$workdir/traffic_summary_issues.json" ]; then
    actual=$(jq 'length' "$workdir/traffic_summary_issues.json" 2>/dev/null || echo 0)
  fi
  runs=$(( runs + 1 ))
  if [ "$actual" != "$expected" ]; then
    echo "  FAIL [$scenario/generate_traffic_summary.sh]: expected $expected issue(s), got $actual"
    failures=$(( failures + 1 ))
  else
    echo "  PASS [$scenario/generate_traffic_summary.sh]: $actual issue(s)"
  fi
done

echo ""
echo "Ran $runs checks, $failures failure(s)."
if [ "$failures" -ne 0 ]; then
  exit 1
fi
echo "All mock tests passed."
