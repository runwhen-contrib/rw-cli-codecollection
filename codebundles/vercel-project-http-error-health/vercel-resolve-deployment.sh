#!/usr/bin/env bash
set -euo pipefail
set -x

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-lib.sh
source "${SCRIPT_DIR}/vercel-lib.sh"

OUTPUT_FILE="vercel_resolve_issues.json"
issues_json='[]'

enc_proj="$(vercel_urlencode "${VERCEL_PROJECT}")"
enc_tid="$(vercel_urlencode "${VERCEL_TEAM_ID}")"
url="${VERCEL_API_BASE}/v9/projects/${enc_proj}?teamId=${enc_tid}"

raw="$(vercel_http_get "$url")" || true
http_code=$(echo "$raw" | tail -n1)
body=$(echo "$raw" | sed '$d')

if [ "$http_code" != "200" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Resolve Project Before Deployment Lookup for \`${VERCEL_PROJECT}\`" \
    --arg details "Project GET failed with HTTP ${http_code}. Run the validate task first." \
    --arg severity "3" \
    --arg next_steps "Fix project access (token, team id, project slug) then rerun." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

project_id=$(echo "$body" | jq -r '.id // empty')
project_name=$(echo "$body" | jq -r '.name // empty')

dep_json="$(vercel_latest_production_deployment_json "$project_id")" || dep_json=""

if [ -z "$dep_json" ] || [ "$dep_json" = "null" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No READY Production Deployment for Project \`${VERCEL_PROJECT}\`" \
    --arg details "Could not find a READY deployment with target=production. Edge-only or paused projects may have no runtime logs." \
    --arg severity "3" \
    --arg next_steps "Deploy to production or verify the project has a production deployment. Preview-only traffic will not appear in production log queries." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "No production deployment found."
  exit 0
fi

dep_uid=$(echo "$dep_json" | jq -r '.uid // empty')
dep_url=$(echo "$dep_json" | jq -r '.url // empty')
created=$(echo "$dep_json" | jq -r '.createdAt // empty')

echo "Production deployment for analysis:"
echo "  project_id=${project_id} (${project_name})"
echo "  deployment_id=${dep_uid}"
echo "  url=${dep_url}"
echo "  createdAt=${created}"
echo "Lookback note: runtime logs use deployment ${dep_uid} as the log source; timestamps are filtered to LOOKBACK_MINUTES."

echo "$issues_json" > "$OUTPUT_FILE"
echo "Resolve step completed. Issues saved to $OUTPUT_FILE"
