#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_client_waiting_output.json"
issues_json='[]'
WAIT_THRESHOLD="${CLIENT_WAITING_THRESHOLD:-0}"

q="sum($(wrap_metric pgbouncer_pools_client_waiting_connections))"
echo "Instant query: $q"

if ! raw=$(prometheus_instant_query "$q"); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Client Waiting Connections" \
    --arg details "curl to Prometheus failed." \
    --arg severity "3" \
    --arg next_steps "Verify PROMETHEUS_URL and credentials." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prometheus_query_status_ok "$raw"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Error for Waiting Connections" \
    --arg details "$(echo "$raw" | jq -c .)" \
    --arg severity "3" \
    --arg next_steps "Confirm pgbouncer_pools_client_waiting_connections is exported for your filters." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

waiters=$(echo "$raw" | jq -r '.data.result[0].value[1] // "0"')
awk -v w="$waiters" -v t="$WAIT_THRESHOLD" 'BEGIN {exit !(w > t)}' && {
  issues_json=$(echo "$issues_json" | jq \
    --arg title "PgBouncer Client Wait Queue Elevated" \
    --arg details "sum(pgbouncer_pools_client_waiting_connections) is ${waiters} (threshold > ${WAIT_THRESHOLD}). Clients are waiting for server connections." \
    --arg severity "3" \
    --arg next_steps "Increase pool capacity (default_pool_size, max_db_connections), add replicas, or reduce app-side connection demand." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
}

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
