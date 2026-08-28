#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Flags when 404 responses exceed a share of sampled request logs in the window.
# Writes vercel_spike_issues.json
# -----------------------------------------------------------------------------

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"
NOT_FOUND_SPIKE_THRESHOLD_PCT="${NOT_FOUND_SPIKE_THRESHOLD_PCT:-15}"
SPIKE_MIN_SAMPLE="${SPIKE_MIN_SAMPLE:-40}"
LOG_SAMPLE_MAX_LINES="${LOG_SAMPLE_MAX_LINES:-50000}"
LOG_FETCH_MAX_SECONDS="${LOG_FETCH_MAX_SECONDS:-90}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_vercel_common.sh"

OUTPUT_ISSUES="vercel_spike_issues.json"
issues_json='[]'

if ! vercel_resolve_token; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Vercel API token missing for 404 spike detection" \
    --arg details "Missing credentials." \
    --argjson severity 4 \
    --arg next_steps "Configure vercel_api_token." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

if ! vercel_resolve_project_id 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot resolve project for 404 spike detection" \
    --arg details "Project resolution failed." \
    --argjson severity 3 \
    --arg next_steps "Check VERCEL_PROJECT and team id." \
    '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  echo "$issues_json" >"$OUTPUT_ISSUES"
  exit 0
fi

if ! vercel_resolve_production_deployment 2>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No production deployment for 404 spike detection" \
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

stats="$(jq -s --argjson cutoff_ms "$cutoff_ms" \
  'map(select(.source != "delimiter"))
   | map(select(.timestampInMs >= $cutoff_ms))
   | map(select(.requestPath != null and .requestPath != ""))
   | map(select(.responseStatusCode != null))
   | . as $rows
   | ($rows | length) as $total
   | ($rows | map(select(.responseStatusCode == 404)) | length) as $n404
   | {
       total: $total,
       not_found: $n404,
       pct: (if $total > 0 then ($n404 * 100.0 / $total) else 0 end)
     }' "$norm")"

total="$(echo "$stats" | jq -r '.total')"
n404="$(echo "$stats" | jq -r '.not_found')"
pct="$(echo "$stats" | jq -r '.pct')"

{
  echo "404 share analysis (last ${LOOKBACK_MINUTES} minutes, sampled logs)"
  echo "Sample lines cap: ${LOG_SAMPLE_MAX_LINES}; min requests for alert: ${SPIKE_MIN_SAMPLE}"
  echo "Total sampled requests with status: ${total}"
  echo "404 count: ${n404}"
  echo "404 share (%): $(printf '%.2f\n' "$pct")"
  echo "Threshold (%): ${NOT_FOUND_SPIKE_THRESHOLD_PCT}"
}

if [ "${total:-0}" -ge "${SPIKE_MIN_SAMPLE}" ] 2>/dev/null; then
  if echo "$stats" | jq -e --argjson th "${NOT_FOUND_SPIKE_THRESHOLD_PCT}" '.pct > $th' >/dev/null; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Elevated 404 share for project \`${VERCEL_PROJECT}\`" \
      --arg details "404s are ${pct}% of ${total} sampled requests (threshold ${NOT_FOUND_SPIKE_THRESHOLD_PCT}%). Missing-route traffic may have spiked." \
      --argjson severity 3 \
      --arg next_steps "Review top 404 paths task, check rewrites and SEO links, and validate recent deployments." \
      '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
  fi
else
  echo "Not enough samples (${total}) to evaluate spike threshold (need >= ${SPIKE_MIN_SAMPLE})."
fi

echo "$issues_json" >"$OUTPUT_ISSUES"
rm -f "$norm"
exit 0
