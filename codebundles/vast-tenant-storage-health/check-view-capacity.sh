#!/usr/bin/env bash
# Identify views approaching or exceeding capacity limits from VMS view metrics.
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

OUTPUT_FILE="view_capacity_issues.json"
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
    "View metrics API error for tenant \`${VAST_TENANT_NAME}\`" \
    "HTTP ${views_code} from /api/prometheusmetrics/views. Body (truncated): ${views_body:0:400}" \
    4)"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

quota_resp="$(vast_fetch_prometheus_metrics "quotas")"
quota_code="$(vast_fetch_http_code "$quota_resp")"
quota_body=""
if [[ "$quota_code" == "200" ]]; then
  quota_body="$(vast_fetch_body "$quota_resp")"
fi

printf '%s' "$views_body" >/tmp/vast_views_metrics.prom
if [[ -n "$quota_body" ]]; then
  printf '%s' "$quota_body" >/tmp/vast_quota_metrics.prom
else
  rm -f /tmp/vast_quota_metrics.prom
fi

analysis="$(VAST_TENANT_NAME="$VAST_TENANT_NAME" VAST_CLUSTER_NAME="$VAST_CLUSTER_NAME" \
  CAPACITY_THRESHOLD="$CAPACITY_THRESHOLD" python3 <<'PY'
import os

tenant = os.environ["VAST_TENANT_NAME"]
cluster = os.environ["VAST_CLUSTER_NAME"]
threshold = float(os.environ["CAPACITY_THRESHOLD"])
views_text = open("/tmp/vast_views_metrics.prom").read()
quota_text = open("/tmp/vast_quota_metrics.prom").read() if os.path.exists("/tmp/vast_quota_metrics.prom") else ""

def parse_metrics(text, prefix):
    out = {}
    for line in text.splitlines():
        if not line or line.startswith("#") or not line.startswith(prefix):
            continue
        if "{" not in line:
            continue
        _, rest = line.split("{", 1)
        labels_part, value_part = rest.rsplit("}", 1)
        labels = "{" + labels_part + "}"
        if tenant and f'tenant_name="{tenant}"' not in labels and f'tenant="{tenant}"' not in labels:
            continue
        if cluster and f'cluster="{cluster}"' not in labels:
            continue
        path = None
        for token in labels_part.split(","):
            token = token.strip()
            if token.startswith('path="'):
                path = token.split("=", 1)[1].strip('"')
        if not path:
            continue
        try:
            out[path] = float(value_part.strip())
        except ValueError:
            pass
    return out

logical = parse_metrics(views_text, "vast_view_logical_capacity")
physical = parse_metrics(views_text, "vast_view_physical_capacity")
quota_used = parse_metrics(quota_text, "vast_quota_used_capacity")
quota_hard = parse_metrics(quota_text, "vast_quota_hard_limit")

rows = []
for path in sorted(set(logical) | set(physical) | set(quota_used) | set(quota_hard)):
    log_val = logical.get(path, 0.0)
    phys_val = physical.get(path, log_val)
    used = quota_used.get(path, log_val)
    hard = quota_hard.get(path)
    util = None
    if hard and hard > 0:
        util = (used / hard) * 100.0
    rows.append((path, log_val, phys_val, used, hard, util))

for path, log_val, phys_val, used, hard, util in rows:
    util_s = f"{util:.2f}" if util is not None else ""
    print(f"{path}\t{log_val}\t{phys_val}\t{used}\t{hard or ''}\t{util_s}")
    if util is not None and util >= threshold:
        sev = 2 if util >= 95 else 3
        print(f"ISSUE\t{path}\t{util:.2f}\t{sev}\tlogical={log_val} physical={phys_val} quota_used={used} quota_hard={hard}")
PY
)"

while IFS= read -r line; do
  if [[ "$line" == ISSUE* ]]; then
    IFS=$'\t' read -r _ view_path util_pct severity details <<<"$line"
    issues_json="$(echo "$issues_json" | jq \
      --arg title "View capacity high for \`${view_path}\` (tenant \`${VAST_TENANT_NAME}\`)" \
      --arg details "View ${view_path} utilization ${util_pct}% exceeds threshold ${CAPACITY_THRESHOLD}%. ${details}" \
      --argjson severity "$severity" \
      --arg next_steps "Review view quota policies, client write patterns, and snapshot retention for path ${view_path}. Free space or raise view/tenant quota in VMS." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')"
  elif [[ -n "$line" ]]; then
    echo "View metrics: $line"
  fi
done <<<"$analysis"

rm -f /tmp/vast_views_metrics.prom /tmp/vast_quota_metrics.prom

echo "$issues_json" >"$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
