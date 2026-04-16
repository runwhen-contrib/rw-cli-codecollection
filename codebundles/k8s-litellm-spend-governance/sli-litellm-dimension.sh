#!/usr/bin/env bash
# Prints a single line: 0 or 1 for SLI sub-metrics. Arg: api | threshold | logs
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"

: "${PROXY_BASE_URL:?Must set PROXY_BASE_URL}"
DIM="${1:?usage: sli-litellm-dimension.sh api|threshold|logs}"
BASE="$(litellm_base_url)"

case "$DIM" in
  api)
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "${BASE}/health" || echo "000")
    if [[ "$code" =~ ^2 ]]; then
      echo 1
      exit 0
    fi
    code2=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 "${BASE}/" || echo "000")
    if [[ "$code2" =~ ^2 ]]; then echo 1; else echo 0; fi
    ;;
  threshold)
    THRESH="${LITELLM_SPEND_THRESHOLD_USD:-0}"
    if awk -v t="$THRESH" 'BEGIN{exit !(t<=0)}'; then
      echo 1
      exit 0
    fi
    read -r START_DATE END_DATE <<<"$(litellm_date_range)"
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    code=$(litellm_get_file "/global/spend/report?start_date=${START_DATE}&end_date=${END_DATE}" "$TMP" || echo "000")
    if [[ "$code" != "200" ]]; then
      echo 1
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
    if awk -v t="$THRESH" -v s="$TOTAL" 'BEGIN{exit !(t>0 && s>t)}'; then echo 0; else echo 1; fi
    ;;
  logs)
    read -r START_DATE END_DATE <<<"$(litellm_date_range)"
    TMP=$(mktemp)
    trap 'rm -f "$TMP"' EXIT
    code=$(litellm_get_file "/spend/logs?start_date=${START_DATE}&end_date=${END_DATE}&summarize=false" "$TMP" || echo "000")
    if [[ "$code" == "403" ]] || [[ "$code" != "200" ]]; then
      echo 1
      exit 0
    fi
    BAD=$(jq -r '
      (if type == "array" then . else [] end)
      | map(tostring)
      | map(select(test("budget_exceeded|rate_limited|BudgetExceeded|RateLimitError|429|502|503|500"; "i")))
      | length
    ' "$TMP" 2>/dev/null || echo "0")
    if [[ "${BAD:-0}" =~ ^[0-9]+$ ]] && [[ "${BAD}" -eq 0 ]]; then echo 1; else echo 0; fi
    ;;
  *)
    echo 0
    ;;
esac
