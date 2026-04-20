#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Compares total LiteLLM spend to LITELLM_SPEND_THRESHOLD_USD
# (0 disables the threshold issue) and prints a breakdown to stdout so the
# runbook report has context even when no issue is raised.
#
# Endpoint strategy (OSS-aware):
#   1. Try /global/spend/report (LiteLLM Enterprise).
#      - If HTTP 200, walk the JSON and sum "total_spend"/"spend" fields.
#      - If HTTP 400/403 with an "Enterprise license" body, fall through.
#   2. OSS fallback: iterate /key/list and sum the `.spend` field across keys.
#      This gives a good approximation of total spend on OSS installs where
#      the enterprise spend-report route is not licensed. Also emits a
#      top-N-keys-by-spend breakdown to the report.
#   3. If both routes fail, record a low-severity informational issue.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"
litellm_init_runtime

OUTPUT_FILE="global_spend_issues.json"
issues_json='[]'
THRESH="${LITELLM_SPEND_THRESHOLD_USD:-0}"
TOP_N="${LITELLM_TOP_N:-5}"
read -r START_DATE END_DATE <<<"$(litellm_date_range)"
TMP=$(mktemp)
litellm_register_cleanup 'rm -f "$TMP"'

SVC="${LITELLM_SERVICE_NAME:-litellm}"
TOTAL=""
SOURCE=""
BREAKDOWN_JSON="[]"

# --- Attempt 1: Enterprise /global/spend/report ------------------------------
PATH_Q="/global/spend/report?start_date=${START_DATE}&end_date=${END_DATE}"
HTTP_CODE=$(litellm_get_file "$PATH_Q" "$TMP" || echo "000")
echo "GET ${PATH_Q} -> HTTP ${HTTP_CODE}"

if [[ "$HTTP_CODE" == "200" ]]; then
  TOTAL=$(python3 -c '
import json,sys
try:
    j=json.load(sys.stdin)
except Exception:
    print("0"); sys.exit(0)
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
  SOURCE="/global/spend/report"
elif [[ "$HTTP_CODE" == "400" || "$HTTP_CODE" == "403" ]] && litellm_is_enterprise_gated "$TMP"; then
  echo "Enterprise-only /global/spend/report unavailable on this OSS proxy; falling back to /key/list aggregation."
else
  body=$(head -c 400 "$TMP" 2>/dev/null || true)
  echo "WARN: ${PATH_Q} returned HTTP ${HTTP_CODE} (body: ${body})"
fi

# --- Attempt 2: OSS fallback via /key/list -----------------------------------
if [[ -z "$TOTAL" ]]; then
  HTTP_CODE_KL=$(litellm_get_file "/key/list" "$TMP" || echo "000")
  echo "GET /key/list -> HTTP ${HTTP_CODE_KL}"
  if [[ "$HTTP_CODE_KL" == "200" ]]; then
    REPORT=$(python3 - "$TMP" "$TOP_N" <<'PY'
import json, sys
path, top_n = sys.argv[1], int(sys.argv[2])
try:
    with open(path) as f:
        raw = json.load(f)
except Exception:
    print(json.dumps({"total": 0.0, "top": [], "count": 0}))
    raise SystemExit
items = None
if isinstance(raw, dict):
    for k in ("keys", "data"):
        if isinstance(raw.get(k), list):
            items = raw[k]; break
if items is None and isinstance(raw, list):
    items = raw
if not isinstance(items, list):
    items = []
rows = []
total = 0.0
for k in items:
    if not isinstance(k, dict): continue
    try: sp = float(k.get("spend") or 0)
    except (TypeError, ValueError): sp = 0.0
    total += sp
    name = (k.get("key_alias") or k.get("alias") or k.get("team_alias")
            or k.get("user_id") or (k.get("token","")[:12] + "...") or "<unknown>")
    try: mb = float(k.get("max_budget")) if k.get("max_budget") is not None else None
    except (TypeError, ValueError): mb = None
    rows.append({"name": name, "spend": round(sp, 6), "max_budget": mb})
rows.sort(key=lambda e: -e["spend"])
print(json.dumps({"total": round(total, 6), "top": rows[:top_n], "count": len(rows)}))
PY
)
    TOTAL=$(jq -r '.total' <<<"$REPORT")
    BREAKDOWN_JSON=$(jq -c '.top' <<<"$REPORT")
    KEY_COUNT=$(jq -r '.count' <<<"$REPORT")
    SOURCE="/key/list (OSS sum-of-keys, ${KEY_COUNT} keys)"
  else
    body=$(head -c 400 "$TMP" 2>/dev/null || true)
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot compute global LiteLLM spend for \`${SVC}\`" \
      --arg details "Both /global/spend/report (enterprise) and /key/list failed on this proxy. Last /key/list HTTP: ${HTTP_CODE_KL}. Body (truncated): ${body}" \
      --argjson severity 3 \
      --arg reproduce_hint "./check-litellm-global-spend.sh" \
      --arg next_steps "Confirm the master key has admin scope, /key/list is reachable, and spend-tracking DB is configured if you need /global/spend/report." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
    echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
    echo "Wrote ${OUTPUT_FILE} (no spend source available)"
    exit 0
  fi
fi

[[ -z "${TOTAL}" ]] && TOTAL=0
echo "Global LiteLLM spend on \`${SVC}\` (source: ${SOURCE}):"
echo "  total_spend_usd=${TOTAL}  window=${START_DATE}..${END_DATE}  threshold=${THRESH}"

if [[ "$BREAKDOWN_JSON" != "[]" ]]; then
  echo "  top ${TOP_N} keys by spend:"
  jq -r '.[] | "    " + .name + " spend=$" + (.spend|tostring)
    + (if .max_budget then " / $" + (.max_budget|tostring) else " (no max_budget)" end)' <<<"$BREAKDOWN_JSON"
fi

if awk -v t="$THRESH" -v s="$TOTAL" 'BEGIN{exit !(t>0 && s>t)}'; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Global LiteLLM spend exceeds threshold for \`${SVC}\`" \
    --arg details "Estimated spend ~${TOTAL} USD vs LITELLM_SPEND_THRESHOLD_USD=${THRESH} over ${START_DATE}..${END_DATE}. Source: ${SOURCE}. Top keys: ${BREAKDOWN_JSON}" \
    --argjson severity 3 \
    --arg reproduce_hint "./check-litellm-global-spend.sh" \
    --arg next_steps "Review key, user, and team budgets; inspect high-cost models; consider rate limits or routing tiers." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
elif awk -v t="$THRESH" 'BEGIN{exit !(t==0)}'; then
  echo "  (LITELLM_SPEND_THRESHOLD_USD=0 disables threshold issue — reporting totals only)"
else
  echo "  spend is below threshold (${TOTAL} <= ${THRESH})"
fi

ISSUE_COUNT=$(jq 'length' <<<"$issues_json")
echo "Emitting ${ISSUE_COUNT} issue(s) from global spend check."
echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
