#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Rolls up request and 404 counts by first path segment (e.g. /blog, /docs).
# Writes vercel_prefix_issues.json (usually empty).
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

OUTPUT_ISSUES="vercel_prefix_issues.json"
issues_json='[]'

if ! vercel_resolve_token; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Vercel API token missing for path prefix summary" \
    --arg details "Missing credentials." \
    --argjson severity 4 \
    --arg next_steps "Configure vercel_api_token." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

if ! vercel_resolve_project_id 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot resolve project for path prefix summary" \
    --arg details "Project resolution failed." \
    --argjson severity 3 \
    --arg next_steps "Check VERCEL_PROJECT and team id." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

if ! vercel_resolve_production_deployment 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No production deployment for path prefix summary" \
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
cutoff_ms=$((now_ms - LOOKBACK_MINUTES * 60 * 1000))

jq -s --argjson cutoff_ms "$cutoff_ms" --argjson topn "$TOP_N_PATHS" \
  'def prefix:
      if . == "/" or . == "" then "(root)"
      else
        (split("/") | if length > 1 then "/" + .[1] else "/" end)
      end;
   map(select(.source != "delimiter"))
   | map(select(.timestampInMs >= $cutoff_ms))
   | map(select(.requestPath != null and .requestPath != ""))
   | map(select(.responseStatusCode != null))
   | map(. + {pfx: (.requestPath | prefix)})
   | group_by(.pfx)
   | map({
       prefix: .[0].pfx,
       requests: length,
       not_found: (map(select(.responseStatusCode == 404)) | length)
     })
   | sort_by(-.requests)
   | .[:$topn]' "$norm" >prefix_agg.json

jq -r '.[] | "\(.requests)\t\(.not_found)\t\(.prefix)"' prefix_agg.json >prefix_table.txt || true

{
  echo "Path prefix rollup (first segment). Window: last ${LOOKBACK_MINUTES} minutes."
  echo "Columns: total_requests, not_found_404, prefix"
  echo ""
  if [ ! -s prefix_table.txt ]; then
    echo "No samples in window."
  else
    column -t prefix_table.txt 2>/dev/null || cat prefix_table.txt
  fi
}

echo "$issues_json" >"$OUTPUT_ISSUES"
rm -f "$norm" prefix_agg.json prefix_table.txt
exit 0
