#!/usr/bin/env bash
set -euo pipefail
set -x

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"
ERROR_RATE_THRESHOLD_PCT="${ERROR_RATE_THRESHOLD_PCT:-1}"
MIN_ERROR_EVENTS="${MIN_ERROR_EVENTS:-5}"
EXCLUDE_404_FROM_4XX="${EXCLUDE_404_FROM_4XX:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-lib.sh
source "${SCRIPT_DIR}/vercel-lib.sh"
# shellcheck source=vercel-analyze-common.sh
source "${SCRIPT_DIR}/vercel-analyze-common.sh"

OUTPUT_FILE="vercel_4xx_issues.json"
issues_json='[]'

vercel_compute_since_until_ms

if ! vercel_resolve_project_and_deployment_ids; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Analyze 4xx Rate — Project or Deployment Unavailable for \`${VERCEL_PROJECT}\`" \
    --arg details "Failed to resolve project id or latest READY production deployment." \
    --arg severity "3" \
    --arg next_steps "Run validate and resolve tasks; confirm production deployment exists." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

LOGF=$(mktemp)
trap 'rm -f "$LOGF"' EXIT

vercel_fetch_runtime_logs_file "$VERCEL_PROJECT_ID" "$VERCEL_DEPLOYMENT_ID" "$SINCE_MS" "$UNTIL_MS" "$LOGF" 5000 || true

filtered="$(vercel_filter_request_logs_json "$LOGF" "$SINCE_MS")"

if [ "${EXCLUDE_404_FROM_4XX}" = "true" ] || [ "${EXCLUDE_404_FROM_4XX}" = "True" ]; then
  four=$(echo "$filtered" | jq '[.[] | select(.responseStatusCode >= 400 and .responseStatusCode <= 499 and .responseStatusCode != 404)] | length')
else
  four=$(echo "$filtered" | jq '[.[] | select(.responseStatusCode >= 400 and .responseStatusCode <= 499)] | length')
fi

total=$(echo "$filtered" | jq 'length')
rate_pct=$(echo "$filtered" | jq -r --argjson f "$four" --argjson t "$total" 'if ($t > 0) then (($f * 100) / $t) else 0 end')

echo "4xx summary (EXCLUDE_404_FROM_4XX=${EXCLUDE_404_FROM_4XX}):"
echo "  total_request_rows=${total} 4xx_count=${four} rate_percent=${rate_pct}"
echo "  lookback_minutes=${LOOKBACK_MINUTES} threshold_pct=${ERROR_RATE_THRESHOLD_PCT} min_events=${MIN_ERROR_EVENTS}"

th="${ERROR_RATE_THRESHOLD_PCT}"
over_rate=$(awk -v r="$rate_pct" -v t="$th" 'BEGIN{ if (r+0 > t+0) print 1; else print 0 }')

if [ "$over_rate" -eq 1 ] && [ "$four" -ge "${MIN_ERROR_EVENTS}" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Elevated 4xx Client Error Rate for Vercel Project \`${VERCEL_PROJECT}\`" \
    --arg details "Sampled ${total} rows with ${four} client errors (~${rate_pct}%, threshold ${th}%). 404 excluded: ${EXCLUDE_404_FROM_4XX}." \
    --arg severity "3" \
    --arg next_steps "Review validation/auth and routing for high-volume 4xx paths; compare top 4xx paths task." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
elif [ "$over_rate" -eq 1 ] && [ "$four" -lt "${MIN_ERROR_EVENTS}" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "4xx Rate Above Threshold but Below Minimum Event Count for \`${VERCEL_PROJECT}\`" \
    --arg details "Rate ${rate_pct}% exceeds ${th}% but only ${four} events (< MIN_ERROR_EVENTS)." \
    --arg severity "2" \
    --arg next_steps "Tune MIN_ERROR_EVENTS or LOOKBACK_MINUTES to reduce noise." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
