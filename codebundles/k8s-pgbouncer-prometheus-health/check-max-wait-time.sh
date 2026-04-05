#!/usr/bin/env bash
set -euo pipefail
set -x

# Flags when pgbouncer_pools_client_maxwait_seconds exceeds MAX_WAIT_SECONDS_THRESHOLD.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_max_wait_time.json}"
MAX_WAIT="${MAX_WAIT_SECONDS_THRESHOLD:-1}"
MATCHER="$(pgbouncer_label_matcher)"
issues_json='[]'

resp="$(prom_instant_query "max(pgbouncer_pools_client_maxwait_seconds${MATCHER})")"

if [ "$(prom_status "$resp")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for max wait time" \
    --arg details "$(echo "$resp" | jq -c .)" \
    --arg severity "3" \
    --arg next_steps "Verify exporter exposes pgbouncer_pools_client_maxwait_seconds and labels match your matcher." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  val="$(echo "$resp" | jq -r '.data.result[0].value[1] // "0"')"
  if awk -v v="$val" -v m="$MAX_WAIT" 'BEGIN{exit !(v+0 > m+0)}'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer max client wait time exceeds threshold" \
      --arg details "max(pgbouncer_pools_client_maxwait_seconds)=$val seconds (threshold ${MAX_WAIT}s)" \
      --arg severity "3" \
      --arg next_steps "Treat as SLO breach: relieve pool pressure, tune pool_mode, or scale capacity; drill into per-database labels if present." \
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
