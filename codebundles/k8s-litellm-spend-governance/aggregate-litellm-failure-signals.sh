#!/usr/bin/env bash
# Summarizes failure modes from /spend/logs for quick triage (counts + optional issue).
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"

: "${PROXY_BASE_URL:?Must set PROXY_BASE_URL}"
OUTPUT_FILE="aggregate_failure_issues.json"
issues_json='[]'
read -r START_DATE END_DATE <<<"$(litellm_date_range)"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

PATH_Q="/spend/logs?start_date=${START_DATE}&end_date=${END_DATE}&summarize=false"
HTTP_CODE=$(litellm_get_file "$PATH_Q" "$TMP" || echo "000")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "aggregate: spend/logs HTTP ${HTTP_CODE}; skipping deep counts"
  echo '[]' >"$OUTPUT_FILE"
  exit 0
fi

# Summarize string matches across log array (jq JSON aggregation)
COUNTS=$(python3 - "$TMP" <<'PY'
import json,sys,re
try:
    with open(sys.argv[1]) as f:
        j=json.load(f)
except Exception:
    print("0 0 0 0")
    raise SystemExit
rows=j if isinstance(j,list) else []
texts=[json.dumps(x) for x in rows]
budget=sum(1 for t in texts if re.search(r"budget_exceeded|BudgetExceeded",t,re.I))
rl=sum(1 for t in texts if re.search(r"rate_limited|RateLimit",t,re.I))
r5=sum(1 for t in texts if re.search(r"\"status_code\"\s*:\s*5\d\d|502|503|500",t))
r4=sum(1 for t in texts if re.search(r"429",t))
print(budget, rl, r5, r4)
PY
)
read -r BUDGET RL R5XX R429 <<<"$COUNTS"

echo "Aggregate failure signals (window ${START_DATE}..${END_DATE}): budget_exceeded~${BUDGET} rate_limited~${RL} 5xx~${R5XX} 429~${R429}"

TOTAL_ISSUES=$(( ${BUDGET:-0} + ${RL:-0} + ${R5XX:-0} + ${R429:-0} ))
if [[ "${TOTAL_ISSUES}" -gt 10 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High volume of blocked or failed LiteLLM requests for \`${LITELLM_SERVICE_NAME:-litellm}\`" \
    --arg details "Heuristic counts from spend logs: budget_exceeded≈${BUDGET}, rate_limited≈${RL}, 5xx≈${R5XX}, 429≈${R429} (see report output for context)." \
    --argjson severity 4 \
    --arg next_steps "Triage provider health, Redis/DB latency, budgets, and rate limits; scale proxy or shed load." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
fi

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
