#!/usr/bin/env bash
# Aggregate 5xx responses by path from Vercel runtime logs.
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
OUT_JSON="vercel_aggregate_5xx.json"
ISSUES_FILE="vercel_aggregate_5xx_issues.json"

vercel_compute_window_ms

if [[ ! -f "$CONTEXT_FILE" ]]; then
  echo "[]" >"$ISSUES_FILE"
  echo "{\"bucket\":\"5xx\",\"paths\":[],\"error\":\"missing ${CONTEXT_FILE}\"}" >"$OUT_JSON"
  exit 0
fi

ids_json="$(jq -c '.deployment_ids' "$CONTEXT_FILE")"
if [[ "$(echo "$ids_json" | jq 'length')" -eq 0 ]]; then
  jq -n \
    --argjson ids "$ids_json" \
    --argjson ws "$WIN_START_MS" \
    --argjson we "$WIN_END_MS" \
    '{bucket:"5xx", paths:[], deployment_ids:$ids, window:{start_ms:$ws,end_ms:$we}}' >"$OUT_JSON"
  echo '[]' >"$ISSUES_FILE"
  exit 0
fi

tmp_lines="$(mktemp)"
vercel_aggregate_status_bucket "$ids_json" 'select(.code >= 500 and .code < 600)' "$tmp_lines"
paths_json="$(vercel_paths_summary_jq <"$tmp_lines")"
rm -f "$tmp_lines"

jq -n \
  --argjson paths "$paths_json" \
  --argjson ids "$ids_json" \
  --argjson ws "$WIN_START_MS" \
  --argjson we "$WIN_END_MS" \
  '{bucket:"5xx", paths:$paths, deployment_ids:$ids, window:{start_ms:$ws,end_ms:$we}}' >"$OUT_JSON"

echo '[]' >"$ISSUES_FILE"
echo "5xx aggregation: $(echo "$paths_json" | jq 'length') path(s). Wrote ${OUT_JSON}"
