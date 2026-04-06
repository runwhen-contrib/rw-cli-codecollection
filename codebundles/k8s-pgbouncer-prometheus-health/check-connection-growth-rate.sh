#!/usr/bin/env bash
set -euo pipefail
set -x
# Flags sustained growth in client active connections over a lookback window.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"

OUTPUT_FILE="connection_growth_analysis.json"
issues_json='[]'
LB="${CONNECTION_GROWTH_LOOKBACK_MINUTES:-45}"
GROWTH_ABS="${CONNECTION_GROWTH_ABSOLUTE_THRESHOLD:-5}"

INNER="$(prom_label_inner)"
Q="sum(pgbouncer_pools_client_active_connections{${INNER}})"

end=$(date +%s)
start=$((end - LB * 60))

echo "Measuring connection growth over ${LB} minutes (absolute increase threshold ${GROWTH_ABS})"

if ! resp="$(prom_range_query "$Q" "$start" "$end" "60s")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Range Query Failed (connection growth)" \
    --arg details "curl error" \
    --arg severity "4" \
    --arg next_steps "Verify Prometheus URL and query_range support." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (range query)" \
    --arg details "$(echo "$resp" | head -c 400)" \
    --arg severity "3" \
    --arg next_steps "Ensure lookback window fits retention; reduce CONNECTION_GROWTH_LOOKBACK_MINUTES if needed." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

# First series (aggregated sum should be single result)
vals=$(echo "$resp" | jq -r '.data.result[0].values[]? | @tsv' 2>/dev/null | tail -n +1)
if [[ -z "$vals" ]]; then
  echo "[]" > "$OUTPUT_FILE"
  echo "No range samples returned"
  jq . "$OUTPUT_FILE"
  exit 0
fi

first=$(echo "$resp" | jq -r '.data.result[0].values[0][1] // empty')
last=$(echo "$resp" | jq -r '.data.result[0].values[-1][1] // empty')
if [[ -z "$first" || -z "$last" ]]; then
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

delta=$(awk -v a="$first" -v b="$last" 'BEGIN { printf "%.4f", b-a }')
if awk -v d="$delta" -v t="$GROWTH_ABS" 'BEGIN { exit !(d+0 >= t+0) }'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Abnormal Growth in PgBouncer Client Active Connections" \
    --arg details "sum(pgbouncer_pools_client_active_connections) increased by ~${delta} over ${LB}m (first=${first}, last=${last}). May indicate connection leaks or ramping load." \
    --arg severity "2" \
    --arg next_steps "Compare with deployment scaling events, review app-side pool settings, and trace clients for unclosed connections." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
jq . "$OUTPUT_FILE"
