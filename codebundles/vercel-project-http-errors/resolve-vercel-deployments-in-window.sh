#!/usr/bin/env bash
# Resolve Vercel deployments whose active interval overlaps the lookback window.
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-http-lib.sh
source "${SCRIPT_DIR}/vercel-http-lib.sh"

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
TOKEN="$(vercel_token_value)"
: "${TOKEN:?Must set VERCEL_TOKEN or vercel_token secret}"
export DEPLOYMENT_ENVIRONMENT="$(printf '%s' "${DEPLOYMENT_ENVIRONMENT:-production}" | tr '[:upper:]' '[:lower:]')"

ISSUES_FILE="vercel_resolve_issues.json"
CONTEXT_FILE="vercel_deployments_context.json"
issues_json='[]'

vercel_compute_window_ms
NOW_MS="$WIN_END_MS"

tmp_deps="$(mktemp)"
if ! vercel_fetch_deployments_all "$tmp_deps"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot list Vercel deployments for project \`${VERCEL_PROJECT_ID}\`" \
    --arg details "The Vercel REST API returned an error when listing deployments. Verify VERCEL_TOKEN, VERCEL_PROJECT_ID, and VERCEL_TEAM_ID (if applicable)." \
    --argjson severity 4 \
    --arg next_steps "Confirm the token has read access to the project and team; retry after fixing credentials." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$ISSUES_FILE"
  echo '{"deployments":[],"deployment_ids":[],"window":{}}' >"$CONTEXT_FILE"
  echo "Failed to list deployments."
  exit 0
fi

ids_json="$(vercel_select_deployments_for_window "$tmp_deps" "$NOW_MS" "$WIN_START_MS" "$WIN_END_MS")"
rm -f "$tmp_deps"

dep_count="$(echo "$ids_json" | jq 'length // 0')"

jq -n \
  --argjson ids "$ids_json" \
  --argjson ws "$WIN_START_MS" \
  --argjson we "$WIN_END_MS" \
  --arg env "${DEPLOYMENT_ENVIRONMENT:-production}" \
  --arg pid "${VERCEL_PROJECT_ID}" \
  '{
    deployment_ids: $ids,
    window: {start_ms: $ws, end_ms: $we, environment: $env},
    project_id: $pid
  }' >"$CONTEXT_FILE"

if [[ "$dep_count" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Vercel deployment covers lookback window for \`${VERCEL_PROJECT_ID}\`" \
    --arg details "No READY deployments in ${DEPLOYMENT_ENVIRONMENT:-production} overlap [${WIN_START_MS}, ${WIN_END_MS}] ms. Logs cannot be attributed for this interval." \
    --argjson severity 3 \
    --arg next_steps "Deploy to the selected environment, widen TIME_WINDOW_HOURS, set DEPLOYMENT_ENVIRONMENT=all, or verify the project has recent production traffic." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" >"$ISSUES_FILE"
echo "Resolved ${dep_count} deployment(s) for log scan. Context: ${CONTEXT_FILE}"
