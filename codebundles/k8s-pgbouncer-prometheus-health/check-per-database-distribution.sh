#!/usr/bin/env bash
set -euo pipefail
set -x

# Ranks databases by current_connections; flags when one database dominates the share.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_per_database_distribution.json}"
MATCHER="$(pgbouncer_label_matcher)"
DOMINANCE="${DATABASE_DOMINANCE_RATIO:-0.45}"
issues_json='[]'

resp="$(prom_instant_query "sum by (database) (pgbouncer_databases_current_connections${MATCHER})")"

if [ "$(prom_status "$resp")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for per-database distribution" \
    --arg details "$(echo "$resp" | jq -c .)" \
    --arg severity "2" \
    --arg next_steps "Verify pgbouncer_databases_current_connections exists and labels match your matcher." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  summary="$(echo "$resp" | jq -c '
    [.data.result[] | {database: .metric.database, v: (.value[1] | tonumber)}]
    | sort_by(.v) | reverse
  ')"
  total="$(echo "$summary" | jq '[.[].v] | add // 0')"
  top="$(echo "$summary" | jq '.[0] // empty')"
  top_db="$(echo "$top" | jq -r '.database // ""')"
  top_v="$(echo "$top" | jq -r '.v // 0')"
  share="$(awk -v t="$top_v" -v s="$total" 'BEGIN { if (s+0 <= 0) { print 0 } else { print t/s } }')"

  if awk -v sh="$share" -v d="$DOMINANCE" 'BEGIN{exit !(sh+0 > d+0)}'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Per-database connection hotspot" \
      --arg topdb "$top_db" \
      --arg share "$share" \
      --arg total "$total" \
      --arg summary "$summary" \
      --arg severity "2" \
      --arg next_steps "Investigate workload on that database, connection leaks, or per-db pool limits; consider splitting traffic." \
      '. += [{
         "title": $title,
         "details": ("Database " + $topdb + " holds ~" + $share + " of total current_connections (sum=" + $total + "). Top series: " + $summary),
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  fi
fi

echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
