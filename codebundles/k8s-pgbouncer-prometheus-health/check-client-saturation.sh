#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_client_saturation_output.json"
issues_json='[]'
THRESHOLD="${CLIENT_SATURATION_PERCENT_THRESHOLD:-80}"

wm_a=$(wrap_metric pgbouncer_pools_client_active_connections)
wm_w=$(wrap_metric pgbouncer_pools_client_waiting_connections)
wm_m=$(wrap_metric pgbouncer_config_max_client_connections)
# Active + waiting vs configured max client connections
q="(sum(${wm_a}) + sum(${wm_w})) / clamp_min(max(${wm_m}), 1) * 100"
filt="$(metric_label_filter)"

echo "Instant query: $q"

if ! raw=$(prometheus_instant_query "$q"); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Query Failed for Client Saturation" \
    --arg details "curl to Prometheus failed while evaluating saturation ratio." \
    --arg severity "3" \
    --arg next_steps "Verify PROMETHEUS_URL and network access to Prometheus." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

if ! prometheus_query_status_ok "$raw"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus Error Evaluating Client Saturation" \
    --arg details "$(echo "$raw" | jq -c .)" \
    --arg severity "3" \
    --arg next_steps "Confirm metrics pgbouncer_pools_* and pgbouncer_config_max_client_connections exist for filter: {$filt}" \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

pct=$(echo "$raw" | jq -r '.data.result[0].value[1] // empty')
if [ -z "$pct" ] || [ "$pct" = "null" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Data for Client Saturation Ratio" \
    --arg details "Prometheus returned no vector value for the saturation expression." \
    --arg severity "2" \
    --arg next_steps "Check that the pgbouncer exporter is scraped and label filters match your deployment." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
else
  cmp=$(awk -v p="$pct" -v t="$THRESHOLD" 'BEGIN {if (p+0 > t+0) exit 0; else exit 1}')
  if [ "$cmp" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "PgBouncer Client Saturation Above ${THRESHOLD}%" \
      --arg details "Estimated saturation is ${pct}% (active+waiting vs max_client_conn). Threshold: ${THRESHOLD}%." \
      --arg severity "3" \
      --arg next_steps "Increase max_client_conn, scale PgBouncer replicas, reduce app pool sizes, or investigate connection leaks." \
      '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  fi
fi

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
