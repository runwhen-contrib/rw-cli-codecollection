#!/usr/bin/env bash
# Evaluate tenant read/write IOPS and bandwidth against configured QoS ceilings.
set -euo pipefail
set -x

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"
: "${VAST_TENANT_NAME:?Must set VAST_TENANT_NAME}"

QOS_UTILIZATION_THRESHOLD="${QOS_UTILIZATION_THRESHOLD:-90}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-vms-helpers.sh
source "${SCRIPT_DIR}/vast-vms-helpers.sh"

vast_require_cmd curl
vast_require_cmd jq
vast_require_cmd python3

OUTPUT_FILE="tenant_qos_issues.json"
issues_json='[]'

if ! vast_auth_configured; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Cannot authenticate to VMS for tenant \`${VAST_TENANT_NAME}\`" \
    "vast_vms_credentials secret missing USERNAME/PASSWORD or API_TOKEN." \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

metrics_resp="$(vast_fetch_prometheus_metrics "tenants")"
metrics_code="$(vast_fetch_http_code "$metrics_resp")"
metrics_body="$(vast_fetch_body "$metrics_resp")"

if [[ "$metrics_code" != "200" ]]; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Tenant QoS metrics API error for \`${VAST_TENANT_NAME}\`" \
    "HTTP ${metrics_code} from /api/prometheusmetrics/tenants." \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

tenants_resp="$(vast_fetch_json_api "/tenants/")"
tenants_code="$(vast_fetch_http_code "$tenants_resp")"
tenants_body="$(vast_fetch_body "$tenants_resp")"
tenant_json="{}"
if [[ "$tenants_code" == "200" ]]; then
  tenant_json="$(printf '%s' "$tenants_body" | vast_find_tenant_json "$tenants_body")"
fi

printf '%s' "$metrics_body" >/tmp/vast_tenant_metrics.prom
printf '%s' "$tenant_json" >/tmp/vast_tenant_config.json

while IFS=$'\t' read -r dimension current limit util_pct severity details; do
  [[ -z "$dimension" ]] && continue
  echo "QoS ${dimension}: current=${current} limit=${limit} util=${util_pct}%"
  if [[ -n "$severity" ]]; then
    issues_json="$(echo "$issues_json" | jq \
      --arg title "Tenant QoS saturation on ${dimension} for \`${VAST_TENANT_NAME}\`" \
      --arg details "${details}" \
      --argjson severity "$severity" \
      --arg next_steps "Review tenant QoS policy limits in VMS, burst workloads, and redistribute IO across views or clients." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
  fi
done < <(QOS_UTILIZATION_THRESHOLD="$QOS_UTILIZATION_THRESHOLD" VAST_TENANT_NAME="$VAST_TENANT_NAME" VAST_CLUSTER_NAME="$VAST_CLUSTER_NAME" python3 <<'PY'
import json, os, re

threshold = float(os.environ["QOS_UTILIZATION_THRESHOLD"])
tenant = os.environ["VAST_TENANT_NAME"]
cluster = os.environ["VAST_CLUSTER_NAME"]
metrics = open("/tmp/vast_tenant_metrics.prom").read()
tenant_cfg = json.load(open("/tmp/vast_tenant_config.json"))

checks = [
    ("read_iops", "vast_tenant_metrics_TenantMetrics_read_iops", ["qos.read_iops", "qos.max_read_iops", "read_iops_limit"]),
    ("write_iops", "vast_tenant_metrics_TenantMetrics_write_iops", ["qos.write_iops", "qos.max_write_iops", "write_iops_limit"]),
    ("read_bw", "vast_tenant_metrics_TenantMetrics_read_bw", ["qos.read_bw", "qos.max_read_bw", "read_bw_limit"]),
    ("write_bw", "vast_tenant_metrics_TenantMetrics_write_bw", ["qos.write_bw", "qos.max_write_bw", "write_bw_limit"]),
]

def metric_max(prefix):
    best = 0.0
    for line in metrics.splitlines():
        if not line or line.startswith("#"):
            continue
        if not any(line.startswith(p) for p in (prefix, prefix + "_avg", prefix + "_sum", prefix + "_count")):
            continue
        if tenant and tenant not in line:
            continue
        if cluster and f'cluster="{cluster}"' not in line:
            continue
        val = line.rsplit(" ", 1)[-1]
        try:
            best = max(best, float(val))
        except ValueError:
            pass
    return best

def cfg_limit(paths):
    cur = tenant_cfg
    for p in paths:
        if isinstance(cur, dict) and p in cur:
            cur = cur[p]
        else:
            return None
    try:
        return float(cur)
    except (TypeError, ValueError):
        return None

for name, metric_prefix, cfg_paths in checks:
    current = metric_max(metric_prefix)
    limit = cfg_limit(cfg_paths)
    if not limit or limit <= 0:
        print(f"{name}\t{current}\t\t\t")
        continue
    util = (current / limit) * 100.0
    sev = ""
    if util >= threshold:
        sev = "4" if util >= 98 else "3"
    details = f"{name} at {util:.1f}% of QoS limit ({current:.2f}/{limit:.2f}) for tenant `{tenant}` on cluster `{cluster}`"
    print(f"{name}\t{current}\t{limit}\t{util:.2f}\t{sev}\t{details}")
PY
)

rm -f /tmp/vast_tenant_metrics.prom /tmp/vast_tenant_config.json

echo "$issues_json" >"$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
