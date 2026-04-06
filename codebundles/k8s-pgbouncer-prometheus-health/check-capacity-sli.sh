#!/usr/bin/env bash
set -euo pipefail
set -x
# Capacity planning SLI: (APP_REPLICAS * APP_DB_POOL_SIZE) / (max_client_conn * PGBOUNCER_REPLICAS)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/prom-common.sh"

: "${PROMETHEUS_URL:?}"
: "${PGBOUNCER_JOB_LABEL:?}"

OUTPUT_FILE="capacity_sli_analysis.json"
issues_json='[]'

if [[ -z "${APP_REPLICAS:-}" || -z "${APP_DB_POOL_SIZE:-}" || -z "${PGBOUNCER_REPLICAS:-}" ]]; then
  echo "[]" > "$OUTPUT_FILE"
  echo "Capacity SLI skipped (set APP_REPLICAS, APP_DB_POOL_SIZE, PGBOUNCER_REPLICAS to enable)"
  jq . "$OUTPUT_FILE"
  exit 0
fi

INNER="$(prom_label_inner)"
Q="max(pgbouncer_config_max_client_connections{${INNER}})"

echo "Computing capacity SLI with APP_REPLICAS=${APP_REPLICAS} APP_DB_POOL_SIZE=${APP_DB_POOL_SIZE} PGBOUNCER_REPLICAS=${PGBOUNCER_REPLICAS}"

if ! resp="$(prom_instant_query "$Q")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Capacity SLI" \
    --arg details "curl error" \
    --arg severity "4" \
    --arg next_steps "Verify Prometheus URL." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prom_check_api "$resp"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus API Error (capacity SLI)" \
    --arg details "$(echo "$resp" | head -c 400)" \
    --arg severity "3" \
    --arg next_steps "Confirm pgbouncer_config_max_client_connections is scraped." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

mcc=$(echo "$resp" | jq -r '.data.result[0].value[1] // "0"')
if awk -v m="$mcc" 'BEGIN { exit !(m+0 <= 0) }'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Invalid max_client_conn for Capacity SLI" \
    --arg details "Could not read pgbouncer_config_max_client_connections from Prometheus (value=${mcc})." \
    --arg severity "2" \
    --arg next_steps "Check exporter scrape and metric availability." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

demand=$(awk -v r="$APP_REPLICAS" -v p="$APP_DB_POOL_SIZE" 'BEGIN { printf "%.4f", r*p }')
supply=$(awk -v m="$mcc" -v r="$PGBOUNCER_REPLICAS" 'BEGIN { printf "%.4f", m*r }')
ratio=$(awk -v d="$demand" -v s="$supply" 'BEGIN { if (s+0==0) { print 999; exit }; printf "%.4f", d/s }')
WARN="${CAPACITY_SLI_WARN_RATIO:-0.85}"

if awk -v r="$ratio" 'BEGIN { exit !(r+0 >= 1.0) }'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Capacity SLI: Demand Meets or Exceeds PgBouncer Supply" \
    --arg details "Estimated demand/supply=${ratio} (demand=${demand} = APP_REPLICAS*APP_DB_POOL_SIZE, supply=${supply} = max_client_conn*PGBOUNCER_REPLICAS, max_client_conn=${mcc})." \
    --arg severity "3" \
    --arg next_steps "Increase PgBouncer replicas, raise max_client_conn carefully, reduce per-pod DB pool size, or scale application." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
elif awk -v r="$ratio" -v w="$WARN" 'BEGIN { exit !(r+0 >= w+0) }'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Capacity SLI: Approaching PgBouncer Limit" \
    --arg details "Estimated demand/supply=${ratio} (warn threshold ${WARN})." \
    --arg severity "2" \
    --arg next_steps "Plan capacity before saturation; validate assumptions for APP_REPLICAS, APP_DB_POOL_SIZE, and PGBOUNCER_REPLICAS." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
jq . "$OUTPUT_FILE"
