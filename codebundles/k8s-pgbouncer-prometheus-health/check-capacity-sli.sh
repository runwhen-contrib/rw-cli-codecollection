#!/usr/bin/env bash
set -euo pipefail
set -x

# Capacity planning SLI: (APP_REPLICAS * APP_DB_POOL_SIZE) / (max_client_conn * PGBOUNCER_REPLICAS)
# Skips when optional inputs are not all provided.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_capacity_sli.json}"
issues_json='[]'

if [ -z "${APP_REPLICAS:-}" ] || [ -z "${APP_DB_POOL_SIZE:-}" ] || [ -z "${PGBOUNCER_REPLICAS:-}" ]; then
  echo "Capacity SLI skipped: set APP_REPLICAS, APP_DB_POOL_SIZE, and PGBOUNCER_REPLICAS to enable."
  echo '[]' | jq '.' > "$OUTPUT_FILE"
  jq '.' "$OUTPUT_FILE"
  exit 0
fi

resp="$(prom_instant_query "max(pgbouncer_config_max_client_connections)")"
if [ "$(prom_status "$resp")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for capacity SLI (max_client_conn)" \
    --arg details "$(echo "$resp" | jq -c .)" \
    --arg severity "2" \
    --arg next_steps "Verify pgbouncer_config_max_client_connections is scraped." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  maxc="$(echo "$resp" | jq -r '.data.result[0].value[1] // "0"')"
  demand="$(awk -v a="${APP_REPLICAS}" -v b="${APP_DB_POOL_SIZE}" 'BEGIN{print a*b}')"
  cap="$(awk -v m="$maxc" -v r="${PGBOUNCER_REPLICAS}" 'BEGIN{print m*r}')"
  ratio="$(awk -v d="$demand" -v c="$cap" 'BEGIN{ if (c+0 <= 0) { print 999 } else { print d/c } }')"

  if awk -v r="$ratio" 'BEGIN{exit !(r+0 >= 1.0)}'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Capacity SLI: app demand meets or exceeds PgBouncer nominal capacity" \
      --arg details "Demand estimate=${demand} (APP_REPLICAS*APP_DB_POOL_SIZE), capacity estimate=${cap} (max_client_conn*PGBOUNCER_REPLICAS), ratio=${ratio}. max_client_conn=${maxc}" \
      --arg severity "2" \
      --arg next_steps "Increase PgBouncer replicas or max_client_conn, reduce per-app pool sizes, or add routing capacity." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  elif awk -v r="$ratio" 'BEGIN{exit !(r+0 >= 0.85)}'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Capacity SLI: approaching PgBouncer nominal capacity" \
      --arg details "Ratio=${ratio} (warning at >=0.85). Demand=${demand}, capacity=${cap}." \
      --arg severity "1" \
      --arg next_steps "Plan capacity changes before saturation; validate assumptions against real pool usage and reserve headroom." \
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
