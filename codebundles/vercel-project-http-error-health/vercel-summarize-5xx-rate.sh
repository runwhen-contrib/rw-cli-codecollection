#!/usr/bin/env bash
set -euo pipefail
set -x

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"
ERROR_RATE_THRESHOLD_PCT="${ERROR_RATE_THRESHOLD_PCT:-1}"
MIN_ERROR_EVENTS="${MIN_ERROR_EVENTS:-5}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-lib.sh
source "${SCRIPT_DIR}/vercel-lib.sh"
# shellcheck source=vercel-analyze-common.sh
source "${SCRIPT_DIR}/vercel-analyze-common.sh"

OUTPUT_FILE="vercel_5xx_issues.json"
issues_json='[]'

vercel_compute_since_until_ms

if ! vercel_resolve_project_and_deployment_ids; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Analyze 5xx Rate — Project or Deployment Unavailable for \`${VERCEL_PROJECT}\`" \
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
total=$(echo "$filtered" | jq 'length')
five=$(echo "$filtered" | jq '[.[] | select(.responseStatusCode >= 500 and .responseStatusCode <= 599)] | length')
rate_pct=$(echo "$filtered" | jq -r --argjson f "$five" --argjson t "$total" 'if ($t > 0) then (($f * 100) / $t) else 0 end')

echo "5xx summary (sampled runtime logs, deployment ${VERCEL_DEPLOYMENT_ID}):"
echo "  total_request_rows=${total} 5xx_count=${five} rate_percent=${rate_pct}"
echo "  lookback_minutes=${LOOKBACK_MINUTES} threshold_pct=${ERROR_RATE_THRESHOLD_PCT} min_events=${MIN_ERROR_EVENTS}"

th="${ERROR_RATE_THRESHOLD_PCT}"
# bc or awk for float compare
over_rate=$(awk -v r="$rate_pct" -v t="$th" 'BEGIN{ if (r+0 > t+0) print 1; else print 0 }')

if [ "$over_rate" -eq 1 ] && [ "$five" -ge "${MIN_ERROR_EVENTS}" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Elevated 5xx Rate for Vercel Project \`${VERCEL_PROJECT}\`" \
    --arg details "In the last ${LOOKBACK_MINUTES} minutes (deployment ${VERCEL_DEPLOYMENT_ID}), sampled ${total} request log rows with ${five} server errors (~${rate_pct}% > threshold ${th}%)." \
    --arg severity "3" \
    --arg next_steps "Inspect failing routes and upstream dependencies; check recent deploys and function logs. Review top 5xx paths task output." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
elif [ "$over_rate" -eq 1 ] && [ "$five" -lt "${MIN_ERROR_EVENTS}" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "5xx Rate Above Threshold but Below Minimum Event Count for \`${VERCEL_PROJECT}\`" \
    --arg details "Rate ${rate_pct}% exceeds ${th}% but only ${five} events (< MIN_ERROR_EVENTS=${MIN_ERROR_EVENTS}). Sample size may be noisy." \
    --arg severity "2" \
    --arg next_steps "Lower MIN_ERROR_EVENTS or widen LOOKBACK_MINUTES if this signal is too sensitive." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
