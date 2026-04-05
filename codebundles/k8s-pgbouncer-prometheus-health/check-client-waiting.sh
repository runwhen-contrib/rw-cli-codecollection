#!/usr/bin/env bash
set -euo pipefail
set -x

# Alerts when client waiting connections exceed a near-zero threshold (pool exhaustion).
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_client_waiting.json}"
MIN_WAIT="${CLIENT_WAITING_MIN_THRESHOLD:-0}"
MATCHER="$(pgbouncer_label_matcher)"
issues_json='[]'

resp="$(prom_instant_query "sum(pgbouncer_pools_client_waiting_connections${MATCHER})")"

if [ "$(prom_status "$resp")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for client waiting connections" \
    --arg details "$(echo "$resp" | jq -c .)" \
    --arg severity "3" \
    --arg next_steps "Verify PROMETHEUS_URL and PGBOUNCER_JOB_LABEL; confirm metric pgbouncer_pools_client_waiting_connections exists." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  val="$(echo "$resp" | jq -r '.data.result[0].value[1] // "0"')"
  if awk -v v="$val" -v m="$MIN_WAIT" 'BEGIN{exit !(v+0 > m+0)}'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer client wait queue buildup" \
      --arg details "sum(pgbouncer_pools_client_waiting_connections)=$val (threshold > ${MIN_WAIT})" \
      --arg severity "3" \
      --arg next_steps "Increase pool_size/default_pool_size, add replicas, or reduce app-side concurrency; inspect slow queries and server pool limits." \
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
