#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Resolves latest READY production deployment for log analysis.
# Outputs JSON issues to vercel_resolve_issues.json (if any).
# -----------------------------------------------------------------------------

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_vercel_common.sh"

OUTPUT_FILE="vercel_resolve_issues.json"
issues_json='[]'

if ! vercel_resolve_token; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Vercel API token missing for project \`${VERCEL_PROJECT}\`" \
    --arg details "Cannot resolve deployment without API credentials." \
    --argjson severity 4 \
    --arg next_steps "Configure the vercel_api_token secret." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

if ! err_body="$(vercel_resolve_project_id 2>&1)"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot resolve project before deployment lookup for \`${VERCEL_PROJECT}\`" \
    --arg details "$err_body" \
    --argjson severity 3 \
    --arg next_steps "Fix VERCEL_PROJECT and VERCEL_TEAM_ID, then retry." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

if ! dep_err="$(vercel_resolve_production_deployment 2>&1)"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No production deployment found for project \`${VERCEL_PROJECT}\`" \
    --arg details "$dep_err" \
    --argjson severity 3 \
    --arg next_steps "Deploy to production or verify project has a READY production deployment." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

echo "Using deployment ${VERCEL_DEPLOYMENT_ID} for project ${VERCEL_PROJECT_ID}"
echo "$issues_json" >"$OUTPUT_FILE"
exit 0
