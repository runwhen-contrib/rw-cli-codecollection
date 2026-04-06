#!/usr/bin/env bash
set -euo pipefail
set -x
# Alerts on sustained client waiting connections (pool exhaustion).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"

OUTPUT_FILE="client_waiting_analysis.json"
issues_json='[]'
WAIT_THR="${CLIENT_WAITING_THRESHOLD:-0.5}"

INNER="$(prom_label_inner)"
Q="sum(pgbouncer_pools_client_waiting_connections{${INNER}})"

echo "Checking client waiting connections (threshold > ${WAIT_THR})"

if ! resp="$(prom_instant_query "$Q")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Client Waiting" \
    --arg details "curl error querying Prometheus" \
    --arg severity "4" \
    --arg next_steps "Verify PROMETHEUS_URL and credentials." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (client waiting)" \
    --arg details "$(echo "$resp" | jq -c . 2>/dev/null | head -c 500)" \
    --arg severity "3" \
    --arg next_steps "Fix PromQL or metric availability." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

val=$(echo "$resp" | jq -r '.data.result[0].value[1] // "0"')
if awk -v v="$val" -v t="$WAIT_THR" 'BEGIN { exit !(v+0 > t+0) }'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "PgBouncer Client Wait Queue Buildup" \
    --arg details "sum(pgbouncer_pools_client_waiting_connections)=${val} (threshold ${WAIT_THR}). Clients are waiting for server connections." \
    --arg severity "3" \
    --arg next_steps "Increase pool_size/default_pool_size, add replicas, tune server-side PostgreSQL capacity, or reduce client concurrency." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
jq . "$OUTPUT_FILE"
