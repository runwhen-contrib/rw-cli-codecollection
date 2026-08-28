#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_exporter_up_output.json"
issues_json='[]'

q="$(wrap_metric pgbouncer_up)"
echo "Instant query: $q"

if ! raw=$(prometheus_instant_query "$q"); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for \`pgbouncer_up\`" \
    --arg details "curl to Prometheus instant query API failed. Check PROMETHEUS_URL and network." \
    --arg severity "4" \
    --arg next_steps "Verify PROMETHEUS_URL, bearer token, and that Prometheus is reachable from the runner." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "Prometheus request failed."
  exit 0
fi

if ! prometheus_query_status_ok "$raw"; then
  err=$(echo "$raw" | jq -r '.error // .data // .')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Returned Error for \`pgbouncer_up\`" \
    --arg details "Response: $err" \
    --arg severity "4" \
    --arg next_steps "Fix the PromQL query or Prometheus availability; confirm pgbouncer_up exists for your scrape config." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

count=$(echo "$raw" | jq '.data.result | length')
if [ "${count:-0}" -eq 0 ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No \`pgbouncer_up\` Series Found for Label Filter" \
    --arg details "Prometheus returned zero time series for pgbouncer_up with the configured job/namespace filters." \
    --arg severity "3" \
    --arg next_steps "Verify ServiceMonitor/PodMonitor targets, PGBOUNCER_JOB_LABEL, and METRIC_NAMESPACE_FILTER against live /metrics or Prometheus targets UI." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
else
  down=$(echo "$raw" | jq -c '[.data.result[]? | select((.value[1] | tonumber) < 1)]')
  dcount=$(echo "$down" | jq 'length')
  if [ "$dcount" -gt 0 ]; then
    for i in $(seq 0 $((dcount - 1))); do
      pod=$(echo "$down" | jq -r ".[$i].metric.pod // .[$i].metric.kubernetes_pod_name // .[$i].metric.instance // \"unknown\"")
      val=$(echo "$down" | jq -r ".[$i].value[1]")
      issues_json=$(echo "$issues_json" | jq \
        --arg title "PgBouncer Exporter Unhealthy (\`pgbouncer_up=0\`) for \`$pod\`" \
        --arg details "pgbouncer_up reports $val for this target. The exporter cannot reach PgBouncer or the process is down." \
        --arg severity "4" \
        --arg next_steps "Check PgBouncer and exporter pods, logs, and network between exporter admin port and PgBouncer. Confirm scrape job matches ${PGBOUNCER_JOB_LABEL}." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    done
  fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
