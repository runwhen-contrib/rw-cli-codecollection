#!/usr/bin/env bash
# Exercise task scripts against the local mock VMS for design-spec scenarios.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_DIR="$ROOT/.test/mock-vms"
PORT=18080

run_scenario() {
  local scenario="$1"
  local expect_min="${2:-0}"
  local expect_max="${3:-999}"

  pkill -f "mock-vms-server.py --port ${PORT}" 2>/dev/null || true
  sleep 0.2
  python3 "$MOCK_DIR/mock-vms-server.py" --port "$PORT" --scenario "$scenario" &
  local pid=$!
  sleep 0.5

  export VAST_VMS_ENDPOINT="http://127.0.0.1:${PORT}"
  export VAST_CLUSTER_NAME="prod-cluster"
  export VAST_TENANT_NAME="demo-tenant"
  export CAPACITY_THRESHOLD="85"
  export QOS_UTILIZATION_THRESHOLD="90"
  export LATENCY_THRESHOLD_MS="10"
  export vast_vms_credentials='{"USERNAME":"test","PASSWORD":"test"}'

  cd "$ROOT"
  rm -f *_issues.json

  case "$scenario" in
    healthy_tenant)
      ./check-tenant-capacity.sh >/dev/null
      ./check-view-capacity.sh >/dev/null
      ./analyze-tenant-qos.sh >/dev/null
      ./check-qos-wait-times.sh >/dev/null
      ;;
    full_view)
      ./check-view-capacity.sh >/dev/null
      ;;
    qos_throttled)
      ./analyze-tenant-qos.sh >/dev/null
      ./check-qos-wait-times.sh >/dev/null
      ;;
  esac

  local total=0
  for f in *_issues.json; do
    [[ -f "$f" ]] || continue
    local c
    c="$(jq 'length' "$f")"
    total=$((total + c))
  done

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if (( total < expect_min || total > expect_max )); then
    echo "Scenario ${scenario} expected ${expect_min}-${expect_max} issues, got ${total}" >&2
    exit 1
  fi
  echo "Scenario ${scenario} OK (${total} issues)"
}

run_scenario healthy_tenant 0 0
run_scenario full_view 1 3
run_scenario qos_throttled 1 4
echo "All mock scenario tests passed"
