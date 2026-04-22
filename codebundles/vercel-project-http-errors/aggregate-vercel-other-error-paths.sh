#!/usr/bin/env bash
# Aggregate additional unhealthy HTTP codes (UNHEALTHY_HTTP_CODES) by path.
set -euo pipefail
set -x

: "${VERCEL_PROJECT_ID:?Must set VERCEL_PROJECT_ID}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vercel-http-lib.sh
source "${SCRIPT_DIR}/vercel-http-lib.sh"
TOKEN="$(vercel_token_value)"
: "${TOKEN:?Must set VERCEL_TOKEN or vercel_token secret}"

CONTEXT_FILE="vercel_deployments_context.json"
OUT_JSON="vercel_aggregate_other.json"
ISSUES_FILE="vercel_aggregate_other_issues.json"
CODES="${UNHEALTHY_HTTP_CODES:-408,429}"
export DEPLOYMENT_ENVIRONMENT="$(printf '%s' "${DEPLOYMENT_ENVIRONMENT:-production}" | tr '[:upper:]' '[:lower:]')"

vercel_compute_window_ms

# Build jq `select` for codes: .code == 408 or .code == 429 ...
code_jq="false"
IFS=',' read -ra RAW <<<"$CODES"
for c in "${RAW[@]}"; do
  c="$(echo "$c" | tr -d '[:space:]')"
  [[ -z "$c" ]] && continue
  [[ "$c" =~ ^[0-9]+$ ]] || continue
  if [[ "$code_jq" == "false" ]]; then
    code_jq="(.code == $c)"
  else
    code_jq="$code_jq or (.code == $c)"
  fi
done

if [[ ! -f "$CONTEXT_FILE" ]]; then
  echo "[]" >"$ISSUES_FILE"
  echo "{\"bucket\":\"other\",\"paths\":[],\"codes\":[]}" >"$OUT_JSON"
  exit 0
fi

ids_json="$(jq -c '.deployment_ids' "$CONTEXT_FILE")"
if [[ "$(echo "$ids_json" | jq 'length')" -eq 0 ]]; then
  jq -n --argjson ids "$ids_json" --arg codes "$CODES" \
    '{bucket:"other", paths:[], codes: ($codes | split(",") | map(gsub("^\\s+|\\s+$";""))), deployment_ids:$ids}' >"$OUT_JSON"
  echo '[]' >"$ISSUES_FILE"
  exit 0
fi

tmp_lines="$(mktemp)"
if [[ "$code_jq" == "false" ]]; then
  paths_json='[]'
else
  vercel_aggregate_status_bucket "$ids_json" "select($code_jq)" "$tmp_lines"
  paths_json="$(vercel_paths_summary_jq <"$tmp_lines")"
fi
rm -f "$tmp_lines"

jq -n \
  --argjson paths "$paths_json" \
  --argjson ids "$ids_json" \
  --arg codes "$CODES" \
  --argjson ws "$WIN_START_MS" \
  --argjson we "$WIN_END_MS" \
  '{bucket:"other", paths:$paths, codes: ($codes | split(",") | map(gsub("^\\s+|\\s+$";""))), deployment_ids:$ids, window:{start_ms:$ws,end_ms:$we}}' >"$OUT_JSON"

echo '[]' >"$ISSUES_FILE"
echo "Other-error aggregation: $(echo "$paths_json" | jq 'length') path(s). Wrote ${OUT_JSON}"
