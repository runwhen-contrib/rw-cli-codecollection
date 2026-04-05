#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# Fails when pgbouncer_up = 0 for any target series (exporter or PgBouncer down).
# Writes JSON issues to OUTPUT_FILE.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_exporter_up.json}"
MATCHER="$(pgbouncer_label_matcher)"
issues_json='[]'

echo "Querying pgbouncer_up for matcher ${MATCHER}"

resp="$(prom_instant_query "pgbouncer_up${MATCHER}")"
if [ "$(prom_status "$resp")" != "success" ]; then
  err="$(echo "$resp" | jq -r '.error // .data // .')"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for pgbouncer_up" \
    --arg details "API response: $err" \
    --arg severity "4" \
    --arg next_steps "Verify PROMETHEUS_URL, authentication, and that the PgBouncer exporter is scraped." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  cnt="$(echo "$resp" | jq '.data.result | length')"
  if [ "${cnt:-0}" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "No pgbouncer_up series matched selector" \
      --arg details "Query returned 0 results for pgbouncer_up${MATCHER}. Scrape or label mismatch." \
      --arg severity "3" \
      --arg next_steps "Confirm PGBOUNCER_JOB_LABEL and METRIC_NAMESPACE_FILTER match ServiceMonitor labels; verify targets are UP in Prometheus." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  fi
  while read -r line; do
    val="$(echo "$line" | jq -r '.value[1]')"
    metric="$(echo "$line" | jq -c '.metric')"
    if awk -v v="$val" 'BEGIN{exit !(v+0 == 0)}'; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "PgBouncer exporter or process unavailable" \
        --arg details "pgbouncer_up is 0 for series: $metric" \
        --arg severity "4" \
        --arg next_steps "Check PgBouncer and prometheus-community/pgbouncer_exporter pods, logs, and ServiceMonitor targets." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    fi
  done < <(echo "$resp" | jq -c '.data.result[]? // empty')
fi

echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
