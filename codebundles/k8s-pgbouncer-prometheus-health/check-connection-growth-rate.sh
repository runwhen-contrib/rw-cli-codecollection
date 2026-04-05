#!/usr/bin/env bash
set -euo pipefail
set -x

# Uses delta() over a lookback window on client active connections to flag rapid growth.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_connection_growth_rate.json}"
MATCHER="$(pgbouncer_label_matcher)"
WINDOW="${CONNECTION_GROWTH_LOOKBACK:-15m}"
DELTA_THRESHOLD="${CONNECTION_GROWTH_DELTA_THRESHOLD:-8}"
issues_json='[]'

resp="$(prom_instant_query "sum(delta(pgbouncer_pools_client_active_connections${MATCHER}[${WINDOW}]))")"

if [ "$(prom_status "$resp")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for connection growth" \
    --arg details "$(echo "$resp" | jq -c .)" \
    --arg severity "2" \
    --arg next_steps "Confirm delta() is supported and range window ${WINDOW} is valid; verify scrape interval is stable." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  val="$(echo "$resp" | jq -r '.data.result[0].value[1] // "0"')"
  if awk -v v="$val" -v t="$DELTA_THRESHOLD" 'BEGIN{exit !(v+0 > t+0)}'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Abnormal client connection growth over lookback window" \
      --arg details "sum(delta(pgbouncer_pools_client_active_connections[${WINDOW}]))=${val} (threshold ${DELTA_THRESHOLD})." \
      --arg severity "3" \
      --arg next_steps "Investigate connection leaks in apps, pooler settings, and autoscaling events; compare with app replica changes." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  fi
fi

echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
