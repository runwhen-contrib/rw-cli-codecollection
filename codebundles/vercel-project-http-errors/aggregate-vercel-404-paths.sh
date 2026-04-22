#!/usr/bin/env bash
# Aggregate 404 responses by path from Vercel runtime logs for resolved deployments.
set -euo pipefail
set -x

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-http-lib.sh
source "${SCRIPT_DIR}/vercel-http-lib.sh"
TOKEN="$(vercel_token_value)"
: "${TOKEN:?Must set VERCEL_TOKEN or vercel_token secret}"
export DEPLOYMENT_ENVIRONMENT="$(printf '%s' "${DEPLOYMENT_ENVIRONMENT:-production}" | tr '[:upper:]' '[:lower:]')"

CONTEXT_FILE="vercel_deployments_context.json"
OUT_JSON="vercel_aggregate_404.json"
ISSUES_FILE="vercel_aggregate_404_issues.json"

vercel_compute_window_ms

if [[ ! -f "$CONTEXT_FILE" ]]; then
  echo "[]" >"$ISSUES_FILE"
  echo "{\"bucket\":\"404\",\"paths\":[],\"error\":\"missing ${CONTEXT_FILE}; run resolve task first\"}" >"$OUT_JSON"
  echo "Missing ${CONTEXT_FILE}"
  exit 0
fi

ids_json="$(jq -c '.deployment_ids' "$CONTEXT_FILE")"
if [[ "$(echo "$ids_json" | jq 'length')" -eq 0 ]]; then
  jq -n \
    --argjson ids "$ids_json" \
    --argjson ws "$WIN_START_MS" \
    --argjson we "$WIN_END_MS" \
    '{bucket:"404", paths:[], deployment_ids:$ids, window:{start_ms:$ws,end_ms:$we}}' >"$OUT_JSON"
  echo '[]' >"$ISSUES_FILE"
  echo "No deployments to scan for 404s."
  exit 0
fi

tmp_lines="$(mktemp)"
vercel_aggregate_status_bucket "$ids_json" 'select(.code == 404)' "$tmp_lines"
paths_json="$(vercel_paths_summary_jq <"$tmp_lines")"
rm -f "$tmp_lines"

jq -n \
  --argjson paths "$paths_json" \
  --argjson ids "$ids_json" \
  --argjson ws "$WIN_START_MS" \
  --argjson we "$WIN_END_MS" \
  '{bucket:"404", paths:$paths, deployment_ids:$ids, window:{start_ms:$ws,end_ms:$we}}' >"$OUT_JSON"

echo '[]' >"$ISSUES_FILE"
echo "404 aggregation: $(echo "$paths_json" | jq 'length') path(s). Wrote ${OUT_JSON}"
