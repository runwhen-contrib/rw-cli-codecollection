#!/usr/bin/env bash
set -euo pipefail
# Lightweight SLI snapshot: binary 5xx and 4xx health, aggregated score (stdout JSON only).

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

vercel_compute_since_until_ms

score_5xx=1
score_4xx=1

if ! vercel_resolve_project_and_deployment_ids; then
  echo '{"score_5xx":0,"score_4xx":0,"aggregate":0,"detail":"resolve_failed"}'
  exit 0
fi

LOGF=$(mktemp)
trap 'rm -f "$LOGF"' EXIT

vercel_fetch_runtime_logs_file "$VERCEL_PROJECT_ID" "$VERCEL_DEPLOYMENT_ID" "$SINCE_MS" "$UNTIL_MS" "$LOGF" 1500 || true

filtered="$(vercel_filter_request_logs_json "$LOGF" "$SINCE_MS")"
total=$(echo "$filtered" | jq 'length')
five=$(echo "$filtered" | jq '[.[] | select(.responseStatusCode >= 500 and .responseStatusCode <= 599)] | length')

if [ "${EXCLUDE_404_FROM_4XX}" = "true" ] || [ "${EXCLUDE_404_FROM_4XX}" = "True" ]; then
  four=$(echo "$filtered" | jq '[.[] | select(.responseStatusCode >= 400 and .responseStatusCode <= 499 and .responseStatusCode != 404)] | length')
else
  four=$(echo "$filtered" | jq '[.[] | select(.responseStatusCode >= 400 and .responseStatusCode <= 499)] | length')
fi

rate_5=$(echo "$filtered" | jq -r --argjson f "$five" --argjson t "$total" 'if ($t > 0) then (($f * 100) / $t) else 0 end')
rate_4=$(echo "$filtered" | jq -r --argjson f "$four" --argjson t "$total" 'if ($t > 0) then (($f * 100) / $t) else 0 end')

th="${ERROR_RATE_THRESHOLD_PCT}"
over5=$(awk -v r="$rate_5" -v t="$th" 'BEGIN{ if (r+0 > t+0) print 1; else print 0 }')
over4=$(awk -v r="$rate_4" -v t="$th" 'BEGIN{ if (r+0 > t+0) print 1; else print 0 }')

# Mirror runbook: need min events for a failing score when rate high
if [ "$over5" -eq 1 ] && [ "$five" -ge "${MIN_ERROR_EVENTS}" ]; then score_5xx=0; fi
if [ "$over4" -eq 1 ] && [ "$four" -ge "${MIN_ERROR_EVENTS}" ]; then score_4xx=0; fi

aggregate=$(awk -v a="$score_5xx" -v b="$score_4xx" 'BEGIN{ printf "%.4f", (a+b)/2 }')
detail="samples=${total} 5xx=${five}(${rate_5}%) 4xx=${four}(${rate_4}%)"

jq -n \
  --argjson s5 "$score_5xx" \
  --argjson s4 "$score_4xx" \
  --arg agg "$aggregate" \
  --arg d "$detail" \
  '{score_5xx: $s5, score_4xx: $s4, aggregate: ($agg | tonumber), detail: $d}'
