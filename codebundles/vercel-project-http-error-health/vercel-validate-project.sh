#!/usr/bin/env bash
set -euo pipefail
set -x

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-lib.sh
source "${SCRIPT_DIR}/vercel-lib.sh"

OUTPUT_FILE="vercel_validate_issues.json"
issues_json='[]'

enc_proj="$(vercel_urlencode "${VERCEL_PROJECT}")"
enc_tid="$(vercel_urlencode "${VERCEL_TEAM_ID}")"
url="${VERCEL_API_BASE}/v9/projects/${enc_proj}?teamId=${enc_tid}"

if ! raw="$(vercel_http_get "$url")"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot Reach Vercel API for Project \`${VERCEL_PROJECT}\`" \
    --arg details "Network or TLS error calling ${url}" \
    --arg severity "4" \
    --arg next_steps "Verify outbound HTTPS access to api.vercel.com and retry. Confirm VERCEL_API_TOKEN is injected." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "Validation failed (curl error). Issues written to $OUTPUT_FILE"
  exit 0
fi

http_code=$(echo "$raw" | tail -n1)
body=$(echo "$raw" | sed '$d')

if [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Vercel API Authorization Failed for Project \`${VERCEL_PROJECT}\`" \
    --arg details "HTTP ${http_code}: $(echo "$body" | jq -c . 2>/dev/null || echo "$body")" \
    --arg severity "4" \
    --arg next_steps "Create or rotate a Vercel token with team access. Confirm VERCEL_TEAM_ID matches the token scope." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
elif [ "$http_code" = "404" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Vercel Project Not Found: \`${VERCEL_PROJECT}\`" \
    --arg details "HTTP 404 from GET /v9/projects. Response: $(echo "$body" | head -c 2000)" \
    --arg severity "4" \
    --arg next_steps "Verify VERCEL_PROJECT is the slug or id under team VERCEL_TEAM_ID. Check team switcher matches VERCEL_TEAM_ID." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
elif [ "$http_code" != "200" ]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Unexpected Vercel API Response for Project \`${VERCEL_PROJECT}\`" \
    --arg details "HTTP ${http_code}: $(echo "$body" | head -c 2000)" \
    --arg severity "3" \
    --arg next_steps "Retry later, check Vercel status page, and confirm API compatibility." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps
     }]')
fi

if [ "$http_code" = "200" ]; then
  pid=$(echo "$body" | jq -r '.id // empty')
  pname=$(echo "$body" | jq -r '.name // empty')
  echo "Resolved Vercel project: id=${pid} name=${pname}"
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo "Validation finished. Issues saved to $OUTPUT_FILE"
