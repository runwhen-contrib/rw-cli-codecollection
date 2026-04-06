#!/usr/bin/env bash
set -euo pipefail
set -x
# Flags pods whose client active sum deviates from fleet median.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"

OUTPUT_FILE="pod_outliers_analysis.json"
issues_json='[]'
DEV_PCT="${POD_OUTLIER_DEVIATION_PERCENT:-50}"

INNER="$(prom_label_inner)"
Q="sum by (pod) (pgbouncer_pools_client_active_connections{${INNER}})"

echo "Detecting per-pod outliers vs median (deviation threshold ${DEV_PCT}%)"

if ! resp="$(prom_instant_query "$Q")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Pod Aggregation" \
    --arg details "curl error" \
    --arg severity "4" \
    --arg next_steps "Verify Prometheus URL." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (pod outliers)" \
    --arg details "$(echo "$resp" | head -c 400)" \
    --arg severity "3" \
    --arg next_steps "Confirm pod label exists on scraped metrics." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

n=$(echo "$resp" | jq '[.data.result[]?] | length')
if [[ "$n" -lt 2 ]]; then
  echo "[]" > "$OUTPUT_FILE"
  echo "Need at least 2 pods for outlier detection; found ${n}"
  jq . "$OUTPUT_FILE"
  exit 0
fi

median=$(echo "$resp" | jq -r '[.data.result[]?.value[1] | tonumber] | sort | if length == 0 then 0 elif length % 2 == 1 then .[length/2 | floor] else (.[length/2 - 1] + .[length/2]) / 2 end')

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  pod=$(echo "$row" | jq -r '.metric.pod // "unknown"')
  v=$(echo "$row" | jq -r '.value[1] // "0"')
  dev=$(awk -v v="$v" -v m="$median" 'BEGIN { if (m+0 == 0) { print 0; exit }; d=(v-m)/m; if (d<0) d=-d; printf "%.4f", d*100.0 }')
  awk -v d="$dev" -v t="$DEV_PCT" 'BEGIN { exit !(d+0 >= t+0) }' || continue
  issues_json=$(echo "$issues_json" | jq \
    --arg title "PgBouncer Pod Outlier (\`pod=${pod}\`)" \
    --arg details "sum(client_active)=${v}, fleet median≈${median}, relative deviation≈${dev}% (threshold ${DEV_PCT}%)." \
    --arg severity "2" \
    --arg next_steps "Check load balancing to PgBouncer pods, stale clients pinning to one endpoint, or pod-specific network issues." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
done < <(echo "$resp" | jq -c '.data.result[]?')

echo "$issues_json" > "$OUTPUT_FILE"
jq . "$OUTPUT_FILE"
