#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Lists virtual keys via /key/list and flags keys approaching max_budget or
# already expired. Also prints a concise governance breakdown to stdout so the
# runbook report shows context even when no issues are raised:
#
#   * Total keys returned, how many have a max_budget set
#   * Top-N keys by spend
#   * Top-N keys by % of max_budget consumed
#   * Keys expiring within LITELLM_KEY_EXPIRY_SOON_HOURS (default 168h / 7d)
#   * Keys already expired
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"
litellm_init_runtime

OUTPUT_FILE="key_budget_issues.json"
issues_json='[]'
SVC="${LITELLM_SERVICE_NAME:-litellm}"
TOP_N="${LITELLM_TOP_N:-5}"
EXPIRY_SOON_H="${LITELLM_KEY_EXPIRY_SOON_HOURS:-168}"
TMP=$(mktemp)
litellm_register_cleanup 'rm -f "$TMP"'

HTTP_CODE=$(litellm_get_file "/key/list" "$TMP" || echo "000")
echo "GET /key/list -> HTTP ${HTTP_CODE}"

if [[ "$HTTP_CODE" == "403" ]]; then
  body_preview="$(head -c 400 "$TMP" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM key list not accessible for \`${SVC}\`" \
    --arg details "GET /key/list returned HTTP 403. Body preview: ${body_preview:-<empty>}. The current key likely lacks admin scope for /key routes." \
    --argjson severity 2 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Use the configured master key or grant list/get key admin routes." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  echo "Wrote $OUTPUT_FILE (auth denied)"
  exit 0
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  body_preview="$(head -c 400 "$TMP" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
  reason="$(litellm_classify_spend_failure "$HTTP_CODE" "$TMP")"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM key list unavailable for \`${SVC}\`" \
    --arg details "GET /key/list returned HTTP ${HTTP_CODE} (classifier: ${reason}). Body preview: ${body_preview:-<empty>}." \
    --argjson severity 2 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Confirm proxy version, admin API path, and master-key scope; use UI or /user/info for scoped checks instead." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  echo "Wrote $OUTPUT_FILE (HTTP ${HTTP_CODE})"
  exit 0
fi

# Single Python pass extracts all the metrics we want to render AND the
# offender lists used below to emit issues. This avoids parsing /key/list
# five separate times.
REPORT=$(python3 - "$TMP" "$TOP_N" "$EXPIRY_SOON_H" <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta

path, top_n_s, soon_h_s = sys.argv[1], sys.argv[2], sys.argv[3]
top_n = int(top_n_s)
soon_h = float(soon_h_s)

try:
    with open(path) as f:
        raw = json.load(f)
except Exception:
    print(json.dumps({"error": "unparseable /key/list response"}))
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

now = datetime.now(timezone.utc)
soon = now + timedelta(hours=soon_h)

def iso(s):
    if not s or not isinstance(s, str): return None
    s = s.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return None

def label(k):
    return (k.get("key_alias")
            or k.get("alias")
            or k.get("team_alias")
            or k.get("user_id")
            or (k.get("token", "")[:12] + "...")
            or "<unknown>")

scanned = 0
with_budget = 0
with_spend = 0
expired, expiring_soon = [], []
near_budget, over_budget = [], []
top_spend, top_pct = [], []

for k in items:
    if not isinstance(k, dict): continue
    scanned += 1
    mb_raw = k.get("max_budget")
    sp_raw = k.get("spend") or 0
    try: sp = float(sp_raw)
    except (TypeError, ValueError): sp = 0.0
    try: mb = float(mb_raw) if mb_raw is not None else None
    except (TypeError, ValueError): mb = None
    if mb is not None and mb > 0: with_budget += 1
    if sp > 0: with_spend += 1

    name = label(k)
    entry = {"name": name, "spend": round(sp, 6), "max_budget": mb}
    if mb and mb > 0:
        pct = round(100.0 * sp / mb, 2)
        entry["pct"] = pct
        if sp >= mb:
            over_budget.append(entry)
        elif pct >= 90.0:
            near_budget.append(entry)
    top_spend.append(entry)

    exp_dt = iso(k.get("expires"))
    if exp_dt:
        if exp_dt < now:
            expired.append({"name": name, "expires": k.get("expires")})
        elif exp_dt < soon:
            expiring_soon.append({"name": name, "expires": k.get("expires")})

top_spend.sort(key=lambda e: -e["spend"])
top_pct = sorted((e for e in top_spend if e.get("pct") is not None),
                 key=lambda e: -e["pct"])

print(json.dumps({
    "scanned": scanned,
    "with_budget": with_budget,
    "with_spend": with_spend,
    "top_spend": top_spend[:top_n],
    "top_pct": top_pct[:top_n],
    "near_budget": near_budget,
    "over_budget": over_budget,
    "expired": expired,
    "expiring_soon": expiring_soon,
}))
PY
)

if [[ -z "$REPORT" ]] || ! echo "$REPORT" | jq -e . >/dev/null 2>&1; then
  echo "Could not parse /key/list JSON; leaving issues empty."
  echo '[]' >"$OUTPUT_FILE"
  exit 0
fi

SCANNED=$(jq -r '.scanned' <<<"$REPORT")
WITH_BUDGET=$(jq -r '.with_budget' <<<"$REPORT")
WITH_SPEND=$(jq -r '.with_spend' <<<"$REPORT")
NEAR=$(jq -r '.near_budget | length' <<<"$REPORT")
OVER=$(jq -r '.over_budget | length' <<<"$REPORT")
EXPIRED=$(jq -r '.expired | length' <<<"$REPORT")
SOON=$(jq -r '.expiring_soon | length' <<<"$REPORT")

echo "Key inventory on \`${SVC}\`:"
echo "  scanned=${SCANNED} with_max_budget=${WITH_BUDGET} with_recorded_spend=${WITH_SPEND}"
echo "  over_budget=${OVER} near_budget(>=90%)=${NEAR} expired=${EXPIRED} expiring_within_${EXPIRY_SOON_H}h=${SOON}"

echo "  top ${TOP_N} keys by spend:"
jq -r --argjson n "$TOP_N" '.top_spend[:$n] | .[] |
  "    " + .name + " spend=$" + (.spend|tostring)
  + (if .max_budget then " / $" + (.max_budget|tostring) + " (" + ((.pct // 0)|tostring) + "%)" else " (no max_budget)" end)
' <<<"$REPORT"

if [[ "$(jq -r '.top_pct | length' <<<"$REPORT")" -gt 0 ]]; then
  echo "  top ${TOP_N} keys by % of max_budget used:"
  jq -r --argjson n "$TOP_N" '.top_pct[:$n] | .[] |
    "    " + .name + " " + ((.pct // 0)|tostring) + "%  ($" + (.spend|tostring) + " / $" + (.max_budget|tostring) + ")"
  ' <<<"$REPORT"
fi

if [[ "$SOON" -gt 0 ]]; then
  echo "  keys expiring within ${EXPIRY_SOON_H}h:"
  jq -r '.expiring_soon[] | "    " + .name + " expires=" + (.expires // "unknown")' <<<"$REPORT"
fi
if [[ "$EXPIRED" -gt 0 ]]; then
  echo "  already expired:"
  jq -r '.expired[] | "    " + .name + " expires=" + (.expires // "unknown")' <<<"$REPORT"
fi

# --- Emit issues -------------------------------------------------------------
if [[ "$OVER" -gt 0 ]]; then
  names=$(jq -r '[.over_budget[].name] | join(", ")' <<<"$REPORT")
  details_json=$(jq -c '.over_budget' <<<"$REPORT")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Virtual key(s) over max_budget on \`${SVC}\`" \
    --arg details "${OVER} key(s) have spend at or above max_budget: ${names}. Breakdown: ${details_json}" \
    --argjson severity 2 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Rotate or increase max_budget for these keys; traffic using them will be rejected at the proxy." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

if [[ "$NEAR" -gt 0 ]]; then
  names=$(jq -r '[.near_budget[].name] | join(", ")' <<<"$REPORT")
  details_json=$(jq -c '.near_budget' <<<"$REPORT")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Virtual key(s) near max_budget on \`${SVC}\`" \
    --arg details "${NEAR} key(s) have spend >= 90% of max_budget: ${names}. Breakdown: ${details_json}" \
    --argjson severity 3 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Rotate or raise budgets, split traffic across keys, or review team budgets." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

if [[ "$EXPIRED" -gt 0 ]]; then
  names=$(jq -r '[.expired[].name] | join(", ")' <<<"$REPORT")
  details_json=$(jq -c '.expired' <<<"$REPORT")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Expired LiteLLM API key(s) detected for \`${SVC}\`" \
    --arg details "${EXPIRED} key(s) show expires in the past: ${names}. Breakdown: ${details_json}" \
    --argjson severity 2 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Renew or delete expired keys before traffic fails authentication." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

if [[ "$SOON" -gt 0 ]]; then
  names=$(jq -r '[.expiring_soon[].name] | join(", ")' <<<"$REPORT")
  details_json=$(jq -c '.expiring_soon' <<<"$REPORT")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM API key(s) expiring within ${EXPIRY_SOON_H}h on \`${SVC}\`" \
    --arg details "${SOON} key(s) will expire within ${EXPIRY_SOON_H}h: ${names}. Breakdown: ${details_json}" \
    --argjson severity 4 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Rotate or extend expiration on these keys before consumers lose access." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

ISSUE_COUNT=$(jq 'length' <<<"$issues_json")
echo "Emitting ${ISSUE_COUNT} issue(s) from key inventory."

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
