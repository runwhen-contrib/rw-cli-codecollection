#!/usr/bin/env bash
# Detect elevated read/write/metadata latency from tenant and view metrics.
set -euo pipefail
set -x

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"
: "${VAST_TENANT_NAME:?Must set VAST_TENANT_NAME}"

LATENCY_THRESHOLD_MS="${LATENCY_THRESHOLD_MS:-10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-vms-helpers.sh
source "${SCRIPT_DIR}/vast-vms-helpers.sh"

vast_require_cmd curl
vast_require_cmd jq
vast_require_cmd python3

OUTPUT_FILE="tenant_latency_issues.json"
issues_json='[]'

if ! vast_auth_configured; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Cannot authenticate to VMS for tenant \`${VAST_TENANT_NAME}\`" \
    "vast_vms_credentials secret missing USERNAME/PASSWORD or API_TOKEN." \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

tenant_resp="$(vast_fetch_prometheus_metrics "tenants")"
tenant_code="$(vast_fetch_http_code "$tenant_resp")"
tenant_body="$(vast_fetch_body "$tenant_resp")"

views_resp="$(vast_fetch_prometheus_metrics "views")"
views_code="$(vast_fetch_http_code "$views_resp")"
views_body="$(vast_fetch_body "$views_resp")"

if [[ "$tenant_code" != "200" && "$views_code" != "200" ]]; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Latency metrics unavailable for tenant \`${VAST_TENANT_NAME}\`" \
    "Tenant metrics HTTP ${tenant_code}, view metrics HTTP ${views_code}." \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

printf '%s' "$tenant_body" >/tmp/vast_tenant_latency.prom
printf '%s' "$views_body" >/tmp/vast_views_latency.prom

while IFS=$'\t' read -r dimension latency_ms severity details; do
  [[ -z "$dimension" ]] && continue
  echo "Latency ${dimension}: ${latency_ms} ms (threshold ${LATENCY_THRESHOLD_MS} ms)"
  if [[ -n "$severity" ]]; then
    issues_json="$(echo "$issues_json" | jq \
      --arg title "Elevated ${dimension} latency for tenant \`${VAST_TENANT_NAME}\`" \
      --arg details "$details" \
      --argjson severity "$severity" \
      --arg next_steps "Investigate cluster load, QoS throttling, network path, and client IO patterns causing elevated ${dimension} latency." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
  fi
done < <(LATENCY_THRESHOLD_MS="$LATENCY_THRESHOLD_MS" VAST_TENANT_NAME="$VAST_TENANT_NAME" VAST_CLUSTER_NAME="$VAST_CLUSTER_NAME" python3 <<'PY'
import os

threshold = float(os.environ["LATENCY_THRESHOLD_MS"])
tenant = os.environ["VAST_TENANT_NAME"]
cluster = os.environ["VAST_CLUSTER_NAME"]
tenant_metrics = open("/tmp/vast_tenant_latency.prom").read()
view_metrics = open("/tmp/vast_views_latency.prom").read()

latency_prefixes = [
    ("tenant_read_latency", "vast_tenant_metrics_TenantMetrics_read_latency", tenant_metrics),
    ("tenant_write_latency", "vast_tenant_metrics_TenantMetrics_write_latency", tenant_metrics),
    ("view_read_latency", "vast_user_view_read_latency", view_metrics),
    ("view_write_latency", "vast_user_view_write_latency", view_metrics),
]

def max_metric(text, prefix):
    best = 0.0
    found = False
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        if not line.startswith(prefix):
            continue
        if tenant and tenant not in line:
            continue
        if cluster and f'cluster="{cluster}"' not in line:
            continue
        try:
            best = max(best, float(line.rsplit(" ", 1)[-1]))
            found = True
        except ValueError:
            pass
    return best if found else None

for name, prefix, text in latency_prefixes:
    if not text.strip():
        continue
    val = max_metric(text, prefix)
    if val is None:
        continue
    # VAST latency metrics are typically in microseconds; convert to ms when values are large.
    latency_ms = val / 1000.0 if val > 1000 else val
    sev = ""
    if latency_ms >= threshold:
        sev = "4" if latency_ms >= threshold * 2 else "3"
    details = f"{name} measured {latency_ms:.2f} ms (threshold {threshold} ms) for tenant `{tenant}` on cluster `{cluster}`"
    print(f"{name}\t{latency_ms:.2f}\t{sev}\t{details}")
PY
)

rm -f /tmp/vast_tenant_latency.prom /tmp/vast_views_latency.prom

echo "$issues_json" >"$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
