#!/usr/bin/env bash
set -euo pipefail
set -x

# Detects clients waiting while server-side idle capacity exists (misconfiguration signal),
# and databases near max_connections with concurrent pool waits.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_server_pool_balance.json}"
MATCHER="$(pgbouncer_label_matcher)"
POD_LABEL="${METRIC_POD_LABEL:-pod}"
issues_json='[]'

imbalance_q="sum by (${POD_LABEL}, database) (pgbouncer_pools_client_waiting_connections${MATCHER}) > 0 and on(${POD_LABEL},database) sum by (${POD_LABEL}, database) (pgbouncer_pools_server_idle_connections${MATCHER}) > 0"

resp="$(prom_instant_query "$imbalance_q")"

if [ "$(prom_status "$resp")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for server pool balance" \
    --arg details "$(echo "$resp" | jq -c .)" \
    --arg severity "2" \
    --arg next_steps "Confirm metrics expose labels ${POD_LABEL} and database; adjust METRIC_POD_LABEL if your scrape uses kubernetes_pod_name." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  cnt="$(echo "$resp" | jq '[.data.result[] | select(.value[1] | tonumber > 0)] | length')"
  if [ "${cnt:-0}" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Possible pool misconfiguration: clients waiting with server idle headroom" \
      --arg details "Matched ${cnt} (pod,database) groups where waiting>0 and server_idle>0. Raw: $(echo "$resp" | jq -c .data.result)" \
      --arg severity "3" \
      --arg next_steps "Review pool_mode, routing, and per-db pool_size; ensure workloads use the expected user/database pools." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  fi
fi

# Near max database connections with waits
near_q="(
  sum by (${POD_LABEL}, database) (pgbouncer_databases_current_connections${MATCHER})
  /
  sum by (${POD_LABEL}, database) (pgbouncer_databases_max_connections${MATCHER})
) > 0.85
and on(${POD_LABEL},database)
sum by (${POD_LABEL}, database) (pgbouncer_databases_max_connections${MATCHER}) > 0
and on(${POD_LABEL},database)
sum by (${POD_LABEL}, database) (pgbouncer_pools_client_waiting_connections${MATCHER}) > 0"

resp2="$(prom_instant_query "$near_q")"
if [ "$(prom_status "$resp2")" = "success" ]; then
  cnt2="$(echo "$resp2" | jq '[.data.result[] | select(.value[1] | tonumber > 0)] | length')"
  if [ "${cnt2:-0}" -gt 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Database pool near limit with client waits" \
      --arg details "Found ${cnt2} groups with current_connections/max_connections > 85% and client_waiting>0." \
      --arg severity "3" \
      --arg next_steps "Raise per-db max_connections/pool_size on PgBouncer or PostgreSQL, or reduce app concurrency to this database." \
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
