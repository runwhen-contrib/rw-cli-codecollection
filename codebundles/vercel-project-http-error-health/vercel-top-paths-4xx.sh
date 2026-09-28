#!/usr/bin/env bash
set -euo pipefail
set -x

: "${VERCEL_TEAM_ID:?Must set VERCEL_TEAM_ID}"
: "${VERCEL_PROJECT:?Must set VERCEL_PROJECT}"

LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-60}"
EXCLUDE_404_FROM_4XX="${EXCLUDE_404_FROM_4XX:-true}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-lib.sh
source "${SCRIPT_DIR}/vercel-lib.sh"
# shellcheck source=vercel-analyze-common.sh
source "${SCRIPT_DIR}/vercel-analyze-common.sh"

OUTPUT_FILE="vercel_top_4xx_issues.json"
issues_json='[]'

vercel_compute_since_until_ms

if ! vercel_resolve_project_and_deployment_ids; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot List 4xx Paths — Project or Deployment Unavailable for \`${VERCEL_PROJECT}\`" \
    --arg details "Failed to resolve project or deployment for log analysis." \
    --arg severity "3" \
    --arg next_steps "Run validate and resolve-deployment tasks first." \
    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

LOGF=$(mktemp)
trap 'rm -f "$LOGF"' EXIT

vercel_fetch_runtime_logs_file "$VERCEL_PROJECT_ID" "$VERCEL_DEPLOYMENT_ID" "$SINCE_MS" "$UNTIL_MS" "$LOGF" 5000 || true

filtered="$(vercel_filter_request_logs_json "$LOGF" "$SINCE_MS")"

if [ "${EXCLUDE_404_FROM_4XX}" = "true" ] || [ "${EXCLUDE_404_FROM_4XX}" = "True" ]; then
  top_json=$(echo "$filtered" | jq '[.[] | select(.responseStatusCode >= 400 and .responseStatusCode <= 499 and .responseStatusCode != 404) | (.requestPath // "/")] | group_by(.) | map({path: .[0], count: length}) | sort_by(-.count) | .[0:15]')
else
  top_json=$(echo "$filtered" | jq '[.[] | select(.responseStatusCode >= 400 and .responseStatusCode <= 499) | (.requestPath // "/")] | group_by(.) | map({path: .[0], count: length}) | sort_by(-.count) | .[0:15]')
fi

echo "Top paths by 4xx count (EXCLUDE_404_FROM_4XX=${EXCLUDE_404_FROM_4XX}, deployment ${VERCEL_DEPLOYMENT_ID}):"
echo "$top_json" | jq .

echo "$issues_json" > "$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE (informational; issues list typically empty)"
