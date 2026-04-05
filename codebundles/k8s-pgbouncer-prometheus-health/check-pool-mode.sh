#!/usr/bin/env bash
set -euo pipefail
set -x

# Validates pool_mode label on pgbouncer_databases metrics vs EXPECTED_POOL_MODE.
# -----------------------------------------------------------------------------

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"
: "${EXPECTED_POOL_MODE:?Must set EXPECTED_POOL_MODE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/prometheus-common.sh"

OUTPUT_FILE="${OUTPUT_FILE:-check_pool_mode.json}"
MATCHER="$(pgbouncer_label_matcher)"
EXPECTED="${EXPECTED_POOL_MODE}"
issues_json='[]'

resp="$(prom_instant_query "count by (pool_mode) (pgbouncer_databases_current_connections${MATCHER})")"

if [ "$(prom_status "$resp")" != "success" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Prometheus query failed for pool_mode" \
    --arg details "$(echo "$resp" | jq -c .)" \
    --arg severity "2" \
    --arg next_steps "Verify pgbouncer_databases_current_connections exposes pool_mode label (prometheus-community/pgbouncer_exporter)." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
else
  modes="$(echo "$resp" | jq -r '.data.result[] | .metric.pool_mode // empty' | sort -u | paste -sd, -)"
  n="$(echo "$resp" | jq '.data.result | length')"
  if [ "${n:-0}" -eq 0 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Could not determine pool_mode from metrics" \
      --arg details "No time series returned for pgbouncer_databases_current_connections${MATCHER}." \
      --arg severity "2" \
      --arg next_steps "Confirm exporter version and labels; optionally validate with kubectl exec to pgbouncer admin SHOW CONFIG." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  elif [ "${n:-0}" -gt 1 ]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Multiple pool_mode values observed" \
      --arg details "pool_mode values: ${modes}. Expected a single consistent mode (${EXPECTED})." \
      --arg severity "2" \
      --arg next_steps "Review per-database pool_mode in PgBouncer configuration; align with application connection patterns." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": ($severity | tonumber),
         "next_steps": $next_steps
       }]')
  else
    actual="$(echo "$resp" | jq -r '.data.result[0].metric.pool_mode // ""')"
    if [ "$actual" != "$EXPECTED" ]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "PgBouncer pool_mode mismatch" \
        --arg details "Observed pool_mode=${actual}, expected=${EXPECTED}." \
        --arg severity "2" \
        --arg next_steps "Update PgBouncer default_pool_mode / per-database pool_mode, or adjust EXPECTED_POOL_MODE if this is intentional." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    fi
  fi
fi

echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
