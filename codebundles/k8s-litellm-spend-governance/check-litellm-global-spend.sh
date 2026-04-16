#!/usr/bin/env bash
# Compares /global/spend/report total to LITELLM_SPEND_THRESHOLD_USD (0 disables threshold issues).
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"

: "${PROXY_BASE_URL:?Must set PROXY_BASE_URL}"
OUTPUT_FILE="global_spend_issues.json"
issues_json='[]'
THRESH="${LITELLM_SPEND_THRESHOLD_USD:-0}"
read -r START_DATE END_DATE <<<"$(litellm_date_range)"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

PATH_Q="/global/spend/report?start_date=${START_DATE}&end_date=${END_DATE}"
HTTP_CODE=$(litellm_get_file "$PATH_Q" "$TMP" || echo "000")

if [[ "$HTTP_CODE" == "403" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM global spend report forbidden for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "GET /global/spend/report returned HTTP 403. Key may lack spend report permissions." \
    --argjson severity 2 \
    --arg next_steps "Grant get_spend_routes or use the configured LITELLM_MASTER_KEY with spend scope." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  body=$(head -c 800 "$TMP" 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot read global spend report for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "HTTP ${HTTP_CODE}. Body (truncated): ${body}" \
    --argjson severity 3 \
    --arg next_steps "Check PROXY_BASE_URL and proxy logs; confirm spend tracking DB is configured." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

TOTAL=$(python3 -c '
import json,sys
try:
    j=json.load(sys.stdin)
except Exception:
    print("0")
    sys.exit(0)
def walk_sum(o):
    s=0.0
    if isinstance(o, dict):
        for k,v in o.items():
            if k in ("total_spend","spend") and isinstance(v,(int,float)):
                s+=float(v)
            else:
                s+=walk_sum(v)
    elif isinstance(o, list):
        for i in o:
            s+=walk_sum(i)
    return s
print(walk_sum(j))
' <"$TMP")

if [[ -z "${TOTAL}" ]]; then TOTAL=0; fi

echo "Global spend (estimated sum of spend fields in report JSON): ${TOTAL} USD for ${START_DATE}..${END_DATE}"

if awk -v t="$THRESH" -v s="$TOTAL" 'BEGIN{exit !(t>0 && s>t)}'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Global LiteLLM spend exceeds threshold for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "Estimated spend ~${TOTAL} USD vs LITELLM_SPEND_THRESHOLD_USD=${THRESH} over ${START_DATE}..${END_DATE}." \
    --argjson severity 3 \
    --arg next_steps "Review /global/spend/report breakdown, team and key budgets, and provider pricing; adjust budgets or routing as needed." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
