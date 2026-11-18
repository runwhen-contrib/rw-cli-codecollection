#!/usr/bin/env bash
# Compare tenant logical capacity and quota utilization from VMS metrics and REST.
set -euo pipefail
set -x

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

OUTPUT_FILE="tenant_capacity_issues.json"
issues_json='[]'

if ! vast_auth_configured; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Cannot authenticate to VMS for tenant \`${VAST_TENANT_NAME}\`" \
    "vast_vms_credentials secret missing USERNAME/PASSWORD or API_TOKEN." \
    4 \
    "Configure vast_vms_credentials with USERNAME and PASSWORD or API_TOKEN.")"
  echo "$issues_json" >"$OUTPUT_FILE"
  echo "Wrote $OUTPUT_FILE"
  exit 0
fi

tenant_metrics_resp="$(vast_fetch_prometheus_metrics "tenants")"
tenant_metrics_code="$(vast_fetch_http_code "$tenant_metrics_resp")"
tenant_metrics_body="$(vast_fetch_body "$tenant_metrics_resp")"

if [[ "$tenant_metrics_code" != "200" ]]; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Tenant metrics API error for \`${VAST_TENANT_NAME}\` on cluster \`${VAST_CLUSTER_NAME}\`" \
    "HTTP ${tenant_metrics_code} from /api/prometheusmetrics/tenants. Body (truncated): ${tenant_metrics_body:0:400}" \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  echo "Wrote $OUTPUT_FILE"
  exit 0
fi

quota_metrics_resp="$(vast_fetch_prometheus_metrics "quotas")"
quota_metrics_code="$(vast_fetch_http_code "$quota_metrics_resp")"
quota_metrics_body="$(vast_fetch_body "$quota_metrics_resp")"

tenants_resp="$(vast_fetch_json_api "/tenants/")"
tenants_code="$(vast_fetch_http_code "$tenants_resp")"
tenants_body="$(vast_fetch_body "$tenants_resp")"

logical_used="$(vast_prom_metric_sum "$tenant_metrics_body" "vast_tenant_metrics_TenantMetrics_logical_capacity" || true)"
physical_used="$(vast_prom_metric_sum "$tenant_metrics_body" "vast_tenant_metrics_TenantMetrics_physical_capacity" || true)"
drr="$(vast_prom_metric_values "$tenant_metrics_body" "vast_cluster_drr" || true)"

quota_used=""
quota_hard=""
if [[ "$quota_metrics_code" == "200" ]]; then
  quota_used="$(vast_prom_metric_sum "$quota_metrics_body" "vast_quota_used_capacity" || true)"
  quota_hard="$(vast_prom_metric_values "$quota_metrics_body" "vast_quota_hard_limit" || true)"
fi

tenant_quota_hard=""
tenant_quota_soft=""
if [[ "$tenants_code" == "200" ]]; then
  tenant_json="$(printf '%s' "$tenants_body" | vast_find_tenant_json "$tenants_body")"
  tenant_quota_hard="$(printf '%s' "$tenant_json" | jq -r '.capacity_limits.hard_limit // .quota.hard_limit // .hard_quota // empty' 2>/dev/null || true)"
  tenant_quota_soft="$(printf '%s' "$tenant_json" | jq -r '.capacity_limits.soft_limit // .quota.soft_limit // .soft_quota // empty' 2>/dev/null || true)"
fi

used_bytes="${quota_used:-$logical_used}"
limit_bytes="${quota_hard:-$tenant_quota_hard}"

echo "Tenant ${VAST_TENANT_NAME} on cluster ${VAST_CLUSTER_NAME}: logical=${logical_used:-n/a} physical=${physical_used:-n/a} drr=${drr:-n/a} quota_used=${quota_used:-n/a} quota_hard=${quota_hard:-n/a}"

util_pct=""
if [[ -n "$used_bytes" && -n "$limit_bytes" ]]; then
  util_pct="$(vast_percent_util "$used_bytes" "$limit_bytes")"
fi

if [[ -n "$util_pct" ]]; then
  over_threshold="$(python3 - "$util_pct" "$CAPACITY_THRESHOLD" <<'PY'
import sys
util = float(sys.argv[1])
threshold = float(sys.argv[2])
print("yes" if util >= threshold else "no")
PY
)"
  if [[ "$over_threshold" == "yes" ]]; then
    severity=3
    if python3 -c "import sys; print('yes' if float(sys.argv[1]) >= 95 else 'no')" "$util_pct" | grep -q yes; then
      severity=2
    fi
    issues_json="$(echo "$issues_json" | jq \
      --arg title "Tenant capacity utilization high for \`${VAST_TENANT_NAME}\` on cluster \`${VAST_CLUSTER_NAME}\`" \
      --arg details "Utilization ${util_pct}% exceeds threshold ${CAPACITY_THRESHOLD}%. used_bytes=${used_bytes} limit_bytes=${limit_bytes} logical=${logical_used:-unknown} physical=${physical_used:-unknown} drr=${drr:-unknown} soft_quota=${tenant_quota_soft:-unknown}" \
      --argjson severity "$severity" \
      --arg next_steps "Review tenant quotas and data growth on VAST. Increase quota, archive cold data, or expand tenant capacity limits in VMS." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
  fi
elif [[ -z "$limit_bytes" && -n "$logical_used" ]]; then
  echo "No quota limit found in metrics or tenant REST; skipping utilization percentage check."
fi

echo "$issues_json" >"$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
