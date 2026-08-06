#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Ranks paths with highest 404 frequency from runtime request logs.
# Writes vercel_404_rank_issues.json (empty unless API errors).
# -----------------------------------------------------------------------------

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"
TOP_N_PATHS="${TOP_N_PATHS:-25}"
LOG_SAMPLE_MAX_LINES="${LOG_SAMPLE_MAX_LINES:-50000}"
LOG_FETCH_MAX_SECONDS="${LOG_FETCH_MAX_SECONDS:-90}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_vercel_common.sh"

OUTPUT_ISSUES="vercel_404_rank_issues.json"
issues_json='[]'

if ! vercel_resolve_token; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Vercel API token missing for 404 path ranking" \
    --arg details "Missing credentials." \
    --argjson severity 4 \
    --arg next_steps "Configure vercel_api_token." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

if ! vercel_resolve_project_id 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot resolve project for 404 path ranking" \
    --arg details "Project resolution failed." \
    --argjson severity 3 \
    --arg next_steps "Check VERCEL_PROJECT and team id." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

if ! vercel_resolve_production_deployment 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No production deployment for 404 path ranking" \
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

jq -s --argjson cutoff_ms "$cutoff_ms" \
  'map(select(.source != "delimiter"))
   | map(select(.timestampInMs >= $cutoff_ms))
   | map(select(.requestPath != null and .requestPath != ""))
   | map(select(.responseStatusCode == 404))
   | group_by(.requestPath)
   | map({path: .[0].requestPath, count: length})
   | sort_by(-.count)' "$norm" >agg404.json

jq --argjson topn "$TOP_N_PATHS" '.[:$topn] | .[] | "\(.count)\t\(.path)"' agg404.json >table404.txt || true

{
  echo "Top paths by 404 count (last ${LOOKBACK_MINUTES} minutes)"
  echo "Sample capped at ${LOG_SAMPLE_MAX_LINES} lines. Methodology: runtime request logs; edge-cached responses may not appear."
  echo ""
  if [ ! -s table404.txt ]; then
    echo "No 404 samples in window (or stream empty)."
  else
    column -t table404.txt 2>/dev/null || cat table404.txt
  fi
}

echo "$issues_json" >"$OUTPUT_ISSUES"
rm -f "$norm" agg404.json table404.txt
exit 0
