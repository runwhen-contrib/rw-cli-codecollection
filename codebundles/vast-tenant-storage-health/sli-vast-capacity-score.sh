#!/usr/bin/env bash
# Lightweight SLI: tenant quota/capacity utilization below CAPACITY_THRESHOLD.
set -euo pipefail

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"
: "${VAST_TENANT_NAME:?Must set VAST_TENANT_NAME}"

CAPACITY_THRESHOLD="${CAPACITY_THRESHOLD:-85}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-vms-helpers.sh
source "${SCRIPT_DIR}/vast-vms-helpers.sh"

vast_require_cmd curl
vast_require_cmd jq
vast_require_cmd python3

if ! vast_auth_configured; then
  echo '{"score":0,"reason":"missing credentials"}'
  exit 0
fi

quota_resp="$(vast_fetch_prometheus_metrics "quotas")"
quota_code="$(vast_fetch_http_code "$quota_resp")"
quota_body="$(vast_fetch_body "$quota_resp")"

score=1
if [[ "$quota_code" == "200" ]]; then
  util="$(quota_used="$(vast_prom_metric_sum "$quota_body" "vast_quota_used_capacity" || true)"; \
    quota_hard="$(vast_prom_metric_values "$quota_body" "vast_quota_hard_limit" || true)"; \
    if [[ -n "$quota_used" && -n "$quota_hard" ]]; then vast_percent_util "$quota_used" "$quota_hard"; else echo ""; fi)"
  if [[ -n "$util" ]] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < float(sys.argv[2]) else 1)" "$util" "$CAPACITY_THRESHOLD"; then
    score=0
  fi
fi

echo "{\"score\":${score},\"utilization_pct\":\"${util:-unknown}\"}"
