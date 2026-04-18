#!/usr/bin/env bash
# Queries /spend/logs for failure and budget-related signals (structured JSON issues).
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"
litellm_init_runtime

OUTPUT_FILE="spend_logs_issues.json"
issues_json='[]'
read -r START_DATE END_DATE <<<"$(litellm_date_range)"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

PATH_Q="/spend/logs?start_date=${START_DATE}&end_date=${END_DATE}&summarize=false"
HTTP_CODE=$(litellm_get_file "$PATH_Q" "$TMP" || echo "000")

if [[ "$HTTP_CODE" == "403" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM spend logs access denied for service \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "GET ${PATH_Q} returned HTTP 403. The API key may lack spend route permissions or this route requires Enterprise." \
    --argjson severity 3 \
    --arg next_steps "Use a master key or a key with get_spend_routes / admin scope, or confirm LiteLLM Enterprise features are licensed if required." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  echo "Wrote $OUTPUT_FILE (HTTP 403)"
  exit 0
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  body=$(head -c 800 "$TMP" 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot fetch LiteLLM spend logs for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "HTTP ${HTTP_CODE} from /spend/logs. Body (truncated): ${body}" \
    --argjson severity 4 \
    --arg next_steps "Verify PROXY_BASE_URL (port-forward or in-cluster URL), database-backed spend is enabled, and the proxy is healthy." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

# Count rows whose JSON text matches failure / governance keywords (jq JSON scan)
BAD=$(jq -r '
  (if type == "array" then . else [] end)
  | map(tostring)
  | map(select(test("budget_exceeded|rate_limited|BudgetExceeded|RateLimitError|429|\"status\"\\s*:\\s*\"failure\"|Provider|Internal Server Error|503|502|500"; "i")))
  | length
' "$TMP" 2>/dev/null || echo "0")

if [[ "${BAD:-0}" =~ ^[0-9]+$ ]] && [[ "${BAD}" -gt 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Spend logs show failures or budget/rate-limit signals for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "In window ${START_DATE}..${END_DATE} (${RW_LOOKBACK_WINDOW:-24h}), approximately ${BAD} log row(s) matched error/budget/rate-limit heuristics (see raw response in report)." \
    --argjson severity 3 \
    --arg next_steps "Inspect proxy metrics and key/team budgets; review provider outages; confirm database spend logs are complete." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" >"$OUTPUT_FILE"
echo "Spend log scan: suspicious_rows=${BAD} window=${START_DATE}..${END_DATE}. Wrote ${OUTPUT_FILE}"
