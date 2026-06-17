#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/prometheus-common.sh
source "${SCRIPT_DIR}/lib/prometheus-common.sh"

: "${PROMETHEUS_URL:?Must set PROMETHEUS_URL}"
: "${PGBOUNCER_JOB_LABEL:?Must set PGBOUNCER_JOB_LABEL}"

OUTPUT_FILE="check_capacity_sli_output.json"
issues_json='[]'

if [ -z "${APP_REPLICAS:-}" ] || [ -z "${APP_DB_POOL_SIZE:-}" ] || [ -z "${PGBOUNCER_REPLICAS:-}" ]; then
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "Capacity SLI skipped (set APP_REPLICAS, APP_DB_POOL_SIZE, PGBOUNCER_REPLICAS)."
  jq '.' "$OUTPUT_FILE"
  exit 0
fi

wm=$(wrap_metric pgbouncer_config_max_client_connections)
q="max(${wm})"
echo "Instant query: $q"

raw=$(prometheus_instant_query "$q" || true)
if ! prometheus_query_status_ok "${raw:-}" 2>/dev/null; then
  echo '[]' | jq \
    --arg title "Prometheus Error for Capacity SLI" \
    --arg details "Could not read max client connections from metrics." \
    --arg severity "2" \
    --arg next_steps "Confirm pgbouncer_config_max_client_connections is scraped." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]' > "$OUTPUT_FILE"
  exit 0
fi

maxc=$(echo "$raw" | jq -r '.data.result[0].value[1] // "0"')
demand=$(awk -v r="$APP_REPLICAS" -v p="$APP_DB_POOL_SIZE" 'BEGIN {printf "%.0f", r * p}')
cap=$(awk -v m="$maxc" -v pr="$PGBOUNCER_REPLICAS" 'BEGIN {printf "%.0f", m * pr}')

if [ "${cap:-0}" -eq 0 ]; then
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

ratio=$(awk -v d="$demand" -v c="$cap" 'BEGIN {printf "%.4f", d / c}')

awk -v r="$ratio" 'BEGIN {exit !((r + 0) >= 1.0)}' && {
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Capacity SLI: App Demand Meets or Exceeds PgBouncer Capacity" \
    --arg details "Estimated demand is ${demand} (APP_REPLICAS * APP_DB_POOL_SIZE) vs capacity ${cap} (max_client_conn * PGBOUNCER_REPLICAS). Ratio ${ratio}." \
    --arg severity "2" \
    --arg next_steps "Increase PgBouncer replicas or max_client_conn, reduce per-app pool size or app replicas, or add pooler shards." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
}

awk -v r="$ratio" 'BEGIN {exit !((r + 0) >= 0.85 && (r + 0) < 1.0)}' && {
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Capacity SLI: Approaching PgBouncer Limit" \
    --arg details "Demand/capacity ratio is ${ratio} (warning band >= 0.85). Demand ${demand}, capacity ${cap}." \
    --arg severity "1" \
    --arg next_steps "Plan capacity increases before saturation causes client waits and errors." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
}

echo "$issues_json" > "$OUTPUT_FILE"
jq '.' "$OUTPUT_FILE"
