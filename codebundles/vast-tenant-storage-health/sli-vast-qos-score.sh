#!/usr/bin/env bash
# Lightweight SLI: no sustained QoS wait time samples for tenant views.
set -euo pipefail

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"
: "${VAST_TENANT_NAME:?Must set VAST_TENANT_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-vms-helpers.sh
source "${SCRIPT_DIR}/vast-vms-helpers.sh"

vast_require_cmd curl
vast_require_cmd python3

if ! vast_auth_configured; then
  echo '{"score":0,"reason":"missing credentials"}'
  exit 0
fi

views_resp="$(vast_fetch_prometheus_metrics "views")"
views_code="$(vast_fetch_http_code "$views_resp")"
views_body="$(vast_fetch_body "$views_resp")"

score=1
if [[ "$views_code" == "200" ]]; then
  wait_sum="$(printf '%s' "$views_body" | vast_prom_metric_sum "vast_view_metrics_ViewMetrics_qos_wait_for_budget_time" || true)"
  if [[ -n "$wait_sum" ]] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 0 else 1)" "$wait_sum"; then
    score=0
  fi
fi

echo "{\"score\":${score},\"qos_wait_sum\":\"${wait_sum:-0}\"}"
