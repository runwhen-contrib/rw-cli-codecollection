#!/usr/bin/env bash
set -euo pipefail
set -x
# Ranks databases by current_connections share to find hotspots.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"

OUTPUT_FILE="per_database_distribution_analysis.json"
issues_json='[]'
HOTSPOT_PCT="${DATABASE_HOTSPOT_PERCENT_THRESHOLD:-40}"

INNER="$(prom_label_inner)"
Q="sum by (database) (pgbouncer_databases_current_connections{${INNER}})"

echo "Analyzing per-database connection share (hotspot threshold ${HOTSPOT_PCT}% of fleet)"

if ! resp="$(prom_instant_query "$Q")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Per-Database Metrics" \
    --arg details "curl error" \
    --arg severity "4" \
    --arg next_steps "Verify Prometheus URL." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (per-database)" \
    --arg details "$(echo "$resp" | head -c 400)" \
    --arg severity "3" \
    --arg next_steps "Confirm pgbouncer_databases_current_connections exists." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

total=$(echo "$resp" | jq '[.data.result[]?.value[1] | tonumber] | add // 0')
if awk -v t="$total" 'BEGIN { exit !(t+0 <= 0) }'; then
  echo "[]" > "$OUTPUT_FILE"
  echo "No database connection data"
  jq . "$OUTPUT_FILE"
  exit 0
fi

while IFS= read -r row; do
  [[ -z "$row" ]] && continue
  db=$(echo "$row" | jq -r '.metric.database // "unknown"')
  v=$(echo "$row" | jq -r '.value[1] // "0"')
  share=$(awk -v v="$v" -v t="$total" 'BEGIN { if (t>0) printf "%.1f", 100.0*v/t; else print 0 }')
  awk -v s="$share" -v h="$HOTSPOT_PCT" 'BEGIN { exit !(s+0 >= h+0) }' || continue
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Database Connection Hotspot (\`${db}\`)" \
    --arg details "Database ${db} holds ~${share}% of summed pgbouncer_databases_current_connections (threshold ${HOTSPOT_PCT}%). Total summed connections (metric space): ${total}." \
    --arg severity "2" \
    --arg next_steps "Investigate traffic skew, shard workloads, tune per-db pool limits, or scale PostgreSQL for this database." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
done < <(echo "$resp" | jq -c '.data.result[]?')

echo "$issues_json" > "$OUTPUT_FILE"
jq . "$OUTPUT_FILE"
