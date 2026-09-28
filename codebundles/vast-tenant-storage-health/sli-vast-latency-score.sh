#!/usr/bin/env bash
# Lightweight SLI: tenant read/write latency below LATENCY_THRESHOLD_MS.
set -euo pipefail

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"
: "${VAST_TENANT_NAME:?Must set VAST_TENANT_NAME}"

LATENCY_THRESHOLD_MS="${LATENCY_THRESHOLD_MS:-10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-vms-helpers.sh
source "${SCRIPT_DIR}/vast-vms-helpers.sh"

vast_require_cmd curl
vast_require_cmd python3

if ! vast_auth_configured; then
  echo '{"score":0,"reason":"missing credentials"}'
  exit 0
fi

tenant_resp="$(vast_fetch_prometheus_metrics "tenants")"
tenant_code="$(vast_fetch_http_code "$tenant_resp")"
tenant_body="$(vast_fetch_body "$tenant_resp")"

score=1
max_latency=""
if [[ "$tenant_code" == "200" ]]; then
  read_lat="$(printf '%s' "$tenant_body" | vast_prom_metric_values "vast_tenant_metrics_TenantMetrics_read_latency" || true)"
  write_lat="$(printf '%s' "$tenant_body" | vast_prom_metric_values "vast_tenant_metrics_TenantMetrics_write_latency" || true)"
  max_latency="$(python3 - "$read_lat" "$write_lat" <<'PY'
import sys
vals = []
for v in sys.argv[1:]:
    if v:
        try:
            vals.append(float(v))
        except ValueError:
            pass
print(max(vals) if vals else "")
PY
)"
  if [[ -n "$max_latency" ]]; then
    latency_ms="$(python3 -c "v=float('$max_latency'); print(v/1000 if v>1000 else v)")"
    if python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)" "$latency_ms" "$LATENCY_THRESHOLD_MS"; then
      score=0
    fi
  fi
fi

echo "{\"score\":${score},\"max_latency_ms\":\"${latency_ms:-unknown}\"}"
