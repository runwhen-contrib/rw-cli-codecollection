#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_max_wait_time_output.json"
issues_json='[]'
MAXW="${MAX_WAIT_SECONDS_THRESHOLD:-1}"

q="max($(wrap_metric pgbouncer_pools_client_maxwait_seconds))"
echo "Instant query: $q"

if ! raw=$(prometheus_instant_query "$q"); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Max Client Wait" \
    --arg details "curl to Prometheus failed." \
    --arg severity "3" \
    --arg next_steps "Verify PROMETHEUS_URL and credentials." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prometheus_query_status_ok "$raw"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Error for Max Client Wait" \
    --arg details "$(echo "$raw" | jq -c .)" \
    --arg severity "3" \
    --arg next_steps "Confirm pgbouncer_pools_client_maxwait_seconds exists." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

mx=$(echo "$raw" | jq -r '.data.result[0].value[1] // "0"')
awk -v w="$mx" -v t="$MAXW" 'BEGIN {exit !(w > t)}' && {
  issues_json=$(echo "$issues_json" | jq \
    --arg title "PgBouncer Max Client Wait Exceeds ${MAXW}s" \
    --arg details "max(pgbouncer_pools_client_maxwait_seconds) is ${mx}s across filtered series. SLO threshold: ${MAXW}s." \
    --arg severity "3" \
    --arg next_steps "Investigate pool exhaustion, slow upstream queries, or mis-sized pools; correlate with waiting connections and per-database load." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
}

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
