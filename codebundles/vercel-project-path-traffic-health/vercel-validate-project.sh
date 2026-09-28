#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Validates Vercel bearer token and resolves project metadata.
# Outputs JSON issues array to vercel_validate_issues.json
# -----------------------------------------------------------------------------

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_vercel_common.sh"

OUTPUT_FILE="vercel_validate_issues.json"
issues_json='[]'

if ! vercel_resolve_token; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Vercel API token missing for project \`${VERCEL_PROJECT}\`" \
    --arg details "Set secret vercel_api_token or VERCEL_TOKEN for API access." \
    --argjson severity 4 \
    --arg next_steps "Add a valid Vercel token with read access to the team and project." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  echo "Validation failed: missing token."
  exit 0
fi

if ! err_body="$(vercel_resolve_project_id 2>&1)"; then
  sev=3
  details="$err_body"
  if echo "$err_body" | jq -e . >/dev/null 2>&1; then
    code=$(echo "$err_body" | jq -r '.error.code // empty')
    if [ "$code" = "forbidden" ] || [ "$code" = "unauthorized" ]; then
      sev=4
    fi
    details=$(echo "$err_body" | jq -c .)
  fi
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot resolve Vercel project \`${VERCEL_PROJECT}\`" \
    --arg details "$details" \
    --argjson severity "$sev" \
    --arg next_steps "Verify VERCEL_TEAM_ID, project slug or id, and token scope." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
else
  echo "Resolved project id: ${VERCEL_PROJECT_ID}"
fi

echo "$issues_json" >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
exit 0
