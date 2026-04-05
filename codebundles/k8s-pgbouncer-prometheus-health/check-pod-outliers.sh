#!/usr/bin/env bash
set -euo pipefail
set -x

# Flags PgBouncer pods whose client active load deviates from the fleet median.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_pod_outliers.json}"
POD_LABEL="${METRIC_POD_LABEL:-pod}"
RATIO="${POD_OUTLIER_RATIO:-1.4}"
MATCHER="$(pgbouncer_label_matcher)"
issues_json='[]'

resp="$(prom_instant_query "sum by (${POD_LABEL}) (pgbouncer_pools_client_active_connections${MATCHER})")"

if [ "$(prom_status "$resp")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for pod outliers" \
    --arg details "$(echo "$resp" | jq -c .)" \
    --arg severity "2" \
    --arg next_steps "Confirm label ${POD_LABEL} exists on pool metrics; set METRIC_POD_LABEL if your scrape differs." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  arr="$(echo "$resp" | jq '[.data.result[] | (.value[1] | tonumber)] | sort')"
  n="$(echo "$arr" | jq 'length')"
  if [ "${n:-0}" -lt 2 ]; then
    echo "Not enough pod series for outlier detection (need >=2)."
  else
    med="$(echo "$arr" | jq '
      if length % 2 == 1 then
        .[(length-1)/2]
      else
        (.[length/2 - 1] + .[length/2]) / 2
      end
    ')"
    while read -r line; do
      pod="$(echo "$line" | jq -r --arg pl "$POD_LABEL" '.metric[$pl] // .metric.pod // "unknown"')"
      val="$(echo "$line" | jq -r '.value[1] | tonumber')"
      hi="$(awk -v m="$med" -v r="$RATIO" 'BEGIN{print m * r}')"
      if awk -v v="$val" -v h="$hi" 'BEGIN{exit !(v > h)}'; then
        issues_json=$(echo "$issues_json" | jq \
          --arg title "PgBouncer pod outlier: high client active load" \
          --arg details "Pod ${pod} has client_active=${val}, fleet median=${med}, ratio threshold=${RATIO}" \
          --arg severity "3" \
          --arg next_steps "Check Service endpoints, load balancing, and sticky sessions; verify each replica sees similar traffic." \
          '. += [{
             "title": $title,
             "details": $details,
             "severity": ($severity | tonumber),
             "next_steps": $next_steps
           }]')
      fi
    done < <(echo "$resp" | jq -c '.data.result[]? // empty')
  fi
fi

echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
