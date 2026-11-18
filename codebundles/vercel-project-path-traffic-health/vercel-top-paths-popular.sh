#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Ranks top request paths by successful (2xx / optional 3xx) responses.
# Writes vercel_popular_issues.json (usually empty unless API error).
# -----------------------------------------------------------------------------

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"
TOP_N_PATHS="${TOP_N_PATHS:-25}"
INCLUDE_3XX="${INCLUDE_3XX:-true}"
LOG_SAMPLE_MAX_LINES="${LOG_SAMPLE_MAX_LINES:-50000}"
LOG_FETCH_MAX_SECONDS="${LOG_FETCH_MAX_SECONDS:-90}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_vercel_common.sh"

OUTPUT_ISSUES="vercel_popular_issues.json"
issues_json='[]'

if ! vercel_resolve_token; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Vercel API token missing for popular paths report" \
    --arg details "Missing credentials." \
    --argjson severity 4 \
    --arg next_steps "Configure vercel_api_token." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

if ! vercel_resolve_project_id 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot resolve project for popular paths" \
    --arg details "Project resolution failed." \
    --argjson severity 3 \
    --arg next_steps "Check VERCEL_PROJECT and team id." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

if ! vercel_resolve_production_deployment 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No production deployment for popular paths analysis" \
    --arg details "Could not select a deployment." \
    --argjson severity 3 \
    --arg next_steps "Deploy to production first." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

raw="$(mktemp)"
norm="$(mktemp)"
vercel_fetch_runtime_logs_file "$raw"
vercel_normalize_ndjson "$raw" "$norm"
rm -f "$raw"

now_ms="$(python3 -c "import time; print(int(time.time()*1000))")"
lb_ms=$((LOOKBACK_MINUTES * 60 * 1000))
cutoff_ms=$((now_ms - lb_ms))

inc_3=0
if [ "$INCLUDE_3XX" = "true" ] || [ "$INCLUDE_3XX" = "1" ]; then
  inc_3=1
fi

jq -s --argjson cutoff_ms "$cutoff_ms" --argjson inc3 "$inc_3" \
  'map(select(.source != "delimiter"))
   | map(select(.timestampInMs >= $cutoff_ms))
   | map(select(.requestPath != null and .requestPath != ""))
   | map(select(
       (.responseStatusCode >= 200 and .responseStatusCode < 300)
       or ($inc3 == 1 and .responseStatusCode >= 300 and .responseStatusCode < 400)
     ))
   | group_by(.requestPath)
   | map({path: .[0].requestPath, count: length})
   | sort_by(-.count)' "$norm" >popular_agg.json

jq --argjson topn "$TOP_N_PATHS" '.[:$topn] | .[] | "\(.count)\t\(.path)"' popular_agg.json >popular_table.txt || true

{
  echo "Top popular paths (2xx$([ "$inc_3" = "1" ] && echo " and 3xx") ) in last ${LOOKBACK_MINUTES} minutes"
  echo "Sample capped at ${LOG_SAMPLE_MAX_LINES} lines / ${LOG_FETCH_MAX_SECONDS}s fetch. Static edge-cached hits may be absent from runtime logs."
  echo ""
  if [ ! -s popular_table.txt ]; then
    echo "No matching request samples in window (or stream empty)."
  else
    column -t popular_table.txt 2>/dev/null || cat popular_table.txt
  fi
} 

echo "$issues_json" >"$OUTPUT_ISSUES"
rm -f "$norm" popular_agg.json popular_table.txt
exit 0
