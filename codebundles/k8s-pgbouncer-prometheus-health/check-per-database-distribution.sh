#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_per_database_distribution_output.json"
HOTSPOT="${DATABASE_HOTSPOT_PERCENT_THRESHOLD:-50}"

wm_db=$(wrap_metric pgbouncer_databases_current_connections)
wm_pool=$(wrap_metric pgbouncer_pools_client_active_connections)

q="sum by (database) (${wm_db})"
echo "Trying: $q"
raw=$(prometheus_instant_query "$q" || true)

if ! prometheus_query_status_ok "${raw:-}" 2>/dev/null || [ "$(echo "${raw:-{}}" | jq '.data.result | length')" -eq 0 ]; then
  q="sum by (database) (${wm_pool})"
  echo "Fallback: $q"
  raw=$(prometheus_instant_query "$q" || true)
fi

if ! prometheus_query_status_ok "${raw:-}" 2>/dev/null; then
  echo '[]' | jq \
    --arg title "Prometheus Error for Per-Database Distribution" \
    --arg details "Could not query per-database connection metrics." \
    --arg severity "2" \
    --arg next_steps "Confirm pgbouncer_databases_current_connections or pgbouncer_pools_client_active_connections with database label is exported." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]' > "$OUTPUT_FILE"
  exit 0
fi

total=$(echo "$raw" | jq '[.data.result[]? | (.value[1] | tonumber)] | add // 0')

issues_json=$(echo "$raw" | jq -c \
  --argjson thr "$HOTSPOT" \
  --argjson total "$total" \
  '
  if ($total == 0) then []
  else
    [.data.result[] |
      (.value[1] | tonumber) as $v |
      (($v / $total) * 100) as $pct |
      select($pct > $thr) |
      {
        title: ("Database Hotspot: `" + (.metric.database // "unknown") + "`"),
        details: ("Approximately " + (($pct * 10 | floor) / 10 | tostring) + "% of connections (" + ($v|tostring) + " of " + ($total|tostring) + "). Threshold: " + ($thr|tostring) + "%."),
        severity: 2,
        next_steps: "Investigate heavy consumers of this database entry; consider separate pools or sharding."
      }
    ]
  end
  ')

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
