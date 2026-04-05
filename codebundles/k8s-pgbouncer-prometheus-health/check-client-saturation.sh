#!/usr/bin/env bash
set -euo pipefail
set -x

# Compares client active (+ optional waiting) load to pgbouncer_config_max_client_connections.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_client_saturation.json}"
THRESH="${CLIENT_SATURATION_PERCENT_THRESHOLD:-80}"
INCLUDE_WAIT="${INCLUDE_WAITING_IN_SATURATION:-true}"
MATCHER="$(pgbouncer_label_matcher)"
issues_json='[]'

active_q="sum(pgbouncer_pools_client_active_connections${MATCHER})"
if [ "$INCLUDE_WAIT" = "true" ]; then
  load_q="sum(pgbouncer_pools_client_active_connections${MATCHER}) + sum(pgbouncer_pools_client_waiting_connections${MATCHER})"
else
  load_q="$active_q"
fi
max_q="max(pgbouncer_config_max_client_connections)"

resp_load="$(prom_instant_query "$load_q")"
resp_max="$(prom_instant_query "$max_q")"

if [ "$(prom_status "$resp_load")" != "success" ] || [ "$(prom_status "$resp_max")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for client saturation" \
    --arg details "load query status: $(prom_status "$resp_load"); max query status: $(prom_status "$resp_max")" \
    --arg severity "3" \
    --arg next_steps "Verify PromQL label matchers and metric names against your exporter /metrics." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  load="$(echo "$resp_load" | jq -r '.data.result[0].value[1] // "nan"')"
  maxc="$(echo "$resp_max" | jq -r '.data.result[0].value[1] // "nan"')"
  pct="$(awk -v l="$load" -v m="$maxc" 'BEGIN {
    if (m+0 <= 0) { print -1; exit }
    print (l+0) / (m+0) * 100.0
  }')"

  if awk -v p="$pct" -v t="$THRESH" 'BEGIN{exit !(p >= 0 && p+0 > t+0)}'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer client saturation high vs max_client_conn" \
      --arg details "Estimated load (active[+waiting]): $load, max_client_conn: $maxc, percent: $pct, threshold: ${THRESH}%" \
      --arg severity "3" \
      --arg next_steps "Scale PgBouncer max_client_conn or replicas, reduce app pool sizes, or add PgBouncer replicas. Pair with backend max_connections checks." \
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
