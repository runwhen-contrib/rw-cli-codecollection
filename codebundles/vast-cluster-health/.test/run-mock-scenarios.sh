#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export VAST_VMS_ENDPOINT="https://vms.mock.local"
export VAST_CLUSTER_NAME="vast-lab-cluster"
export CAPACITY_THRESHOLD="85"
export CRITICAL_CAPACITY_THRESHOLD="95"
export VAST_VMS_CREDENTIALS_JSON='{"USERNAME":"admin","PASSWORD":"mock"}'

run_scenario() {
  local name="$1"
  local fixture_dir="$ROOT/.test/fixtures/${name}"
  local expected_min="${2:-0}"
  local expected_max="${3:-999}"

  echo "=== Scenario: ${name} ==="
  export VAST_MOCK_FIXTURE_DIR="$fixture_dir"

  rm -f *_output.json
  ./check-vms-cluster-health.sh >/dev/null
  ./check-cluster-capacity.sh >/dev/null
  ./check-node-hardware-health.sh >/dev/null
  ./check-degraded-components.sh >/dev/null
  ./check-replication-status.sh >/dev/null

  total_issues=0
  for f in vms_cluster_health_output.json cluster_capacity_output.json node_hardware_health_output.json degraded_components_output.json replication_status_output.json; do
    count="$(jq 'length' "$f")"
    total_issues=$((total_issues + count))
  done

  echo "Total issues: ${total_issues} (expected between ${expected_min} and ${expected_max})"
  if (( total_issues < expected_min || total_issues > expected_max )); then
    echo "Scenario ${name} FAILED" >&2
    exit 1
  fi

  sli_json="$(./sli-vast-cluster-health-score.sh)"
  echo "SLI scores: ${sli_json}"
}

run_scenario healthy 0 0
run_scenario degraded 2 10
run_scenario capacity_pressure 1 3

echo "All mock scenarios passed"
