#!/usr/bin/env bash
# Inspect QoS wait time metrics and metadata IOPS limits for tenant throttling.
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

OUTPUT_FILE="qos_wait_issues.json"
issues_json='[]'

if ! vast_auth_configured; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Cannot authenticate to VMS for tenant \`${VAST_TENANT_NAME}\`" \
    "vast_vms_credentials secret missing USERNAME/PASSWORD or API_TOKEN." \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

views_resp="$(vast_fetch_prometheus_metrics "views")"
views_code="$(vast_fetch_http_code "$views_resp")"
views_body="$(vast_fetch_body "$views_resp")"

if [[ "$views_code" != "200" ]]; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "QoS wait metrics API error for tenant \`${VAST_TENANT_NAME}\`" \
    "HTTP ${views_code} from /api/prometheusmetrics/views." \
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

printf '%s' "$views_body" >/tmp/vast_views_qos.prom
printf '%s' "$tenant_json" >/tmp/vast_tenant_qos.json

analysis="$(QOS_UTILIZATION_THRESHOLD="$QOS_UTILIZATION_THRESHOLD" VAST_TENANT_NAME="$VAST_TENANT_NAME" VAST_CLUSTER_NAME="$VAST_CLUSTER_NAME" python3 <<'PY'
import json, os

threshold = float(os.environ["QOS_UTILIZATION_THRESHOLD"])
tenant = os.environ["VAST_TENANT_NAME"]
cluster = os.environ["VAST_CLUSTER_NAME"]
metrics = open("/tmp/vast_views_qos.prom").read()
tenant_cfg = json.load(open("/tmp/vast_tenant_qos.json"))

wait_total = 0.0
wait_samples = 0
md_iops = 0.0
for line in metrics.splitlines():
    if not line or line.startswith("#"):
        continue
    if tenant and tenant not in line:
        continue
    if cluster and f'cluster="{cluster}"' not in line:
        continue
    if "qos_wait_for_budget_time" in line:
        try:
            wait_total += float(line.rsplit(" ", 1)[-1])
            wait_samples += 1
        except ValueError:
            pass
    if "read_md_iops" in line or "write_md_iops" in line:
        try:
            md_iops = max(md_iops, float(line.rsplit(" ", 1)[-1]))
        except ValueError:
            pass

avg_wait = wait_total / wait_samples if wait_samples else 0.0
md_limit = None
for key in ("metadata_iops", "md_iops", "max_metadata_iops"):
    val = tenant_cfg.get("qos", {}).get(key) if isinstance(tenant_cfg.get("qos"), dict) else tenant_cfg.get(key)
    if val is not None:
        try:
            md_limit = float(val)
            break
        except (TypeError, ValueError):
            pass

print(f"summary\tavg_qos_wait={avg_wait:.4f}\tmd_iops={md_iops:.2f}\tmd_limit={md_limit or 'unknown'}")

if wait_samples and avg_wait > 0:
    print(f"ISSUE\tQoS wait time elevated\tTenant `{tenant}` average qos_wait_for_budget_time={avg_wait:.4f} across {wait_samples} view metric series.\t4")

if md_limit and md_limit > 0:
    util = (md_iops / md_limit) * 100.0
    if util >= threshold:
        sev = 4 if util >= 98 else 3
        print(f"ISSUE\tMetadata IOPS near QoS limit\tMetadata IOPS {md_iops:.2f}/{md_limit:.2f} ({util:.1f}%) for tenant `{tenant}`.\t{sev}")
PY
)"

while IFS=$'\t' read -r kind title details severity; do
  if [[ "$kind" == "summary" ]]; then
    echo "${title}"
    continue
  fi
  if [[ "$kind" == "ISSUE" ]]; then
    issues_json="$(echo "$issues_json" | jq \
      --arg title "${title} for \`${VAST_TENANT_NAME}\`" \
      --arg details "$details" \
      --argjson severity "$severity" \
      --arg next_steps "Inspect tenant QoS policy, metadata IOPS limits, and workloads causing sustained budget waits. Adjust QoS or spread metadata-heavy operations." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
  fi
done <<<"$analysis"

rm -f /tmp/vast_views_qos.prom /tmp/vast_tenant_qos.json

echo "$issues_json" >"$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
