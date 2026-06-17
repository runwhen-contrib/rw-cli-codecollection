#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_server_pool_balance_output.json"
issues_json='[]'

wm_wait=$(wrap_metric pgbouncer_pools_client_waiting_connections)
wm_idle=$(wrap_metric pgbouncer_pools_server_idle_connections)
wm_used=$(wrap_metric pgbouncer_pools_server_used_connections)

q1="sum(${wm_wait})"
q2="sum(${wm_idle})"
q3="sum(${wm_used})"

echo "Queries: $q1 ; $q2 ; $q3"

fetch_scalar() {
  local query="$1"
  local raw
  if ! raw=$(prometheus_instant_query "$query"); then
    echo ""
    return 1
  fi
  if ! prometheus_query_status_ok "$raw"; then
    echo ""
    return 1
  fi
  echo "$raw" | jq -r '.data.result[0].value[1] // "0"'
}

w=$(fetch_scalar "$q1") || w=""
if [ -z "$w" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Pool Balance" \
    --arg details "Could not evaluate waiting connections: $q1" \
    --arg severity "3" \
    --arg next_steps "Verify Prometheus connectivity and that pool metrics exist." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

i=$(fetch_scalar "$q2") || i=""
u=$(fetch_scalar "$q3") || u=""

awk -v w="${w:-0}" -v id="${i:-0}" 'BEGIN {
  if (w > 0 && id > 0) exit 0
  exit 1
}' && {
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Possible Pool Misconfiguration: Clients Waiting With Idle Servers" \
    --arg details "Clients are waiting (sum=${w}) while server_idle connections exist (sum=${i}). This pattern can indicate wrong pool_mode, routing, or auth/database mismatch." \
    --arg severity "3" \
    --arg next_steps "Verify pool_mode vs workload, check per-database pool routing, and review pgbouncer.ini auth and database definitions." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
}

awk -v w="${w:-0}" -v us="${u:-0}" 'BEGIN {
  if (w > 0 && us > 0) exit 0
  exit 1
}' && {
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Server Pool Pressure With Concurrent Client Waits" \
    --arg details "Clients are waiting (sum=${w}) while server_used is non-zero (sum=${u}). Investigate pool sizing and upstream PostgreSQL capacity." \
    --arg severity "2" \
    --arg next_steps "Review default_pool_size and max_db_connections vs PostgreSQL max_connections; check for slow queries holding server slots." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
}

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
