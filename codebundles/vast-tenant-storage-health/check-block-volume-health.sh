#!/usr/bin/env bash
# Monitor block volume IOPS, bandwidth, and latency via /api/prometheusmetrics/volumes.
set -euo pipefail
set -x

: "${VAST_VMS_ENDPOINT:?Must set VAST_VMS_ENDPOINT}"
: "${VAST_CLUSTER_NAME:?Must set VAST_CLUSTER_NAME}"
: "${VAST_TENANT_NAME:?Must set VAST_TENANT_NAME}"

LATENCY_THRESHOLD_MS="${LATENCY_THRESHOLD_MS:-10}"
QOS_UTILIZATION_THRESHOLD="${QOS_UTILIZATION_THRESHOLD:-90}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-vms-helpers.sh
source "${SCRIPT_DIR}/vast-vms-helpers.sh"

vast_require_cmd curl
vast_require_cmd jq
vast_require_cmd python3

OUTPUT_FILE="block_volume_issues.json"
issues_json='[]'

if ! vast_auth_configured; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Cannot authenticate to VMS for tenant \`${VAST_TENANT_NAME}\`" \
    "vast_vms_credentials secret missing USERNAME/PASSWORD or API_TOKEN." \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

volumes_resp="$(vast_fetch_prometheus_metrics "volumes")"
volumes_code="$(vast_fetch_http_code "$volumes_resp")"
volumes_body="$(vast_fetch_body "$volumes_resp")"

if [[ "$volumes_code" == "404" ]]; then
  issues_json="$(echo "$issues_json" | jq \
    --arg title "Block volume metrics endpoint unavailable for tenant \`${VAST_TENANT_NAME}\`" \
    --arg details "HTTP 404 from /api/prometheusmetrics/volumes. Block volume metrics require VAST Cluster 5.4.3+ and at least one IO on monitored volumes." \
    --argjson severity 4 \
    --arg next_steps "Upgrade cluster to 5.4.3+, enable live monitoring on block volumes, and ensure volumes have recent IO." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

if [[ "$volumes_code" != "200" ]]; then
  issues_json="$(vast_add_api_error_issue "$issues_json" \
    "Block volume metrics API error for tenant \`${VAST_TENANT_NAME}\`" \
    "HTTP ${volumes_code} from /api/prometheusmetrics/volumes." \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

printf '%s' "$volumes_body" >/tmp/vast_volume_metrics.prom

while IFS=$'\t' read -r volume title details severity; do
  [[ -z "$volume" ]] && continue
  echo "Block volume ${volume}: ${details}"
  issues_json="$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "Inspect block volume mapping, host multipath, QoS policy, and recent IO errors for volume ${volume}. Toggle live monitoring if metrics are stale." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
done < <(LATENCY_THRESHOLD_MS="$LATENCY_THRESHOLD_MS" QOS_UTILIZATION_THRESHOLD="$QOS_UTILIZATION_THRESHOLD" VAST_TENANT_NAME="$VAST_TENANT_NAME" VAST_CLUSTER_NAME="$VAST_CLUSTER_NAME" python3 <<'PY'
import os

latency_threshold = float(os.environ["LATENCY_THRESHOLD_MS"])
tenant = os.environ["VAST_TENANT_NAME"]
cluster = os.environ["VAST_CLUSTER_NAME"]
metrics = open("/tmp/vast_volume_metrics.prom").read()

volumes = {}

for line in metrics.splitlines():
    if not line or line.startswith("#") or "{" not in line:
        continue
    if tenant and tenant not in line:
        continue
    if cluster and f'cluster="{cluster}"' not in line:
        continue
    name_part, rest = line.split("{", 1)
    labels_part, value_part = rest.rsplit("}", 1)
    vol = None
    for token in labels_part.split(","):
        token = token.strip()
        for key in ("volume", "volume_name", "name"):
            if token.startswith(f'{key}="'):
                vol = token.split("=", 1)[1].strip('"')
    if not vol:
        continue
    try:
        val = float(value_part.strip())
    except ValueError:
        continue
    entry = volumes.setdefault(vol, {"read_iops": 0.0, "write_iops": 0.0, "read_latency": 0.0, "write_latency": 0.0, "read_bw": 0.0, "write_bw": 0.0})
    metric = name_part.strip()
    if "read_iops" in metric:
        entry["read_iops"] = max(entry["read_iops"], val)
    elif "write_iops" in metric:
        entry["write_iops"] = max(entry["write_iops"], val)
    elif "read_latency" in metric:
        entry["read_latency"] = max(entry["read_latency"], val)
    elif "write_latency" in metric:
        entry["write_latency"] = max(entry["write_latency"], val)
    elif "read_bw" in metric:
        entry["read_bw"] = max(entry["read_bw"], val)
    elif "write_bw" in metric:
        entry["write_bw"] = max(entry["write_bw"], val)

if not volumes:
    print("none\tNo block volume metrics for tenant\tNo volume series matched tenant/cluster filters. Enable live monitoring and send IO to volumes.\t4")
    raise SystemExit

for vol, data in sorted(volumes.items()):
    total_iops = data["read_iops"] + data["write_iops"]
    max_latency = max(data["read_latency"], data["write_latency"])
    latency_ms = max_latency / 1000.0 if max_latency > 1000 else max_latency
    if total_iops == 0:
        print(f"{vol}\tBlock volume `{vol}` shows zero IO\tVolume has no read/write IOPS in exported metrics; verify host connectivity and monitoring.\t4")
    if latency_ms >= latency_threshold:
        sev = 4 if latency_ms >= latency_threshold * 2 else 3
        print(f"{vol}\tElevated block volume latency on `{vol}`\tread_latency={data['read_latency']:.2f} write_latency={data['write_latency']:.2f} (~{latency_ms:.2f} ms)\t{sev}")
PY
)

rm -f /tmp/vast_volume_metrics.prom

echo "$issues_json" >"$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
