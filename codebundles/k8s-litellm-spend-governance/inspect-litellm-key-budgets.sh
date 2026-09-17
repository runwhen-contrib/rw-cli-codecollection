#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Lists virtual keys via /key/list and flags keys approaching max_budget or
# already expired. Also prints a concise governance breakdown to stdout so the
# runbook report shows context even when no issues are raised:
#
#   * Total keys returned, how many have a max_budget set
#   * Keys with no max_budget (ungoverned) — sev 4
#   * Keys exceeding LITELLM_KEY_SPEND_ALERT_USD — sev 3
#   * Top-N keys by spend
#   * Top-N keys by % of max_budget consumed
#   * Keys expiring within LITELLM_KEY_EXPIRY_SOON_HOURS (default 168h / 7d)
#   * Keys already expired
#   * Upcoming budget resets
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
SPEND_ALERT="${LITELLM_KEY_SPEND_ALERT_USD:-0}"
TMP=$(mktemp)
litellm_register_cleanup 'rm -f "$TMP"'

HTTP_CODE_KL=$(litellm_get_file "/key/list?size=100" "$TMP" || echo "000")
echo "GET /key/list -> HTTP ${HTTP_CODE_KL}"
BASE_URL=$(litellm_base_url)
TOKEN=$(litellm_master_token)

if [[ "$HTTP_CODE_KL" != "200" ]]; then
  body_preview="$(head -c 400 "$TMP" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
  reason="$(litellm_classify_spend_failure "$HTTP_CODE_KL" "$TMP")"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM key list unavailable for \`${SVC}\`" \
    --arg details "GET /key/list returned HTTP ${HTTP_CODE_KL} (classifier: ${reason}). Body preview: ${body_preview:-<empty>}." \
    --argjson severity 2 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Confirm proxy version, admin API path, and master-key scope." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  echo "Wrote $OUTPUT_FILE (HTTP ${HTTP_CODE_KL})"
  exit 0
fi

# /key/list returns key hashes. For each hash, call /key/info?key=<hash>
# to get spend, max_budget, key_alias, expires, etc.
REPORT=$(python3 - "$TMP" "$BASE_URL" "$TOKEN" "$TOP_N" "$EXPIRY_SOON_H" "$SPEND_ALERT" <<'PY'
import json, sys, urllib.request
from datetime import datetime, timezone, timedelta

path, base_url, token, top_n_s, soon_h_s, spend_alert_s = sys.argv[1:]
top_n = int(top_n_s)
soon_h = float(soon_h_s)
spend_alert = float(spend_alert_s)

try:
    with open(path) as f:
        raw = json.load(f)
except Exception:
    print(json.dumps({"error": "unparseable /key/list response"}))
    raise SystemExit

hashes = raw.get("keys", raw) if isinstance(raw, dict) else raw
if not isinstance(hashes, list):
    hashes = []
total_hashes = raw.get("total_count", len(hashes)) if isinstance(raw, dict) else len(hashes)
echo("scanned_from_list: {} hashes out of total_count={}".format(len(hashes), total_hashes))

now = datetime.now(timezone.utc)
soon = now + timedelta(hours=soon_h)

def iso(ss):
    if not ss or not isinstance(ss, str): return None
    s = ss.replace("Z", "+00:00")
    try:
        dt = datetime.fromisoformat(s)
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return None

scanned = 0
with_budget = 0
with_spend = 0
no_budget = []
high_spend = []
budget_reset_soon = []
expired, expiring_soon = [], []
near_budget, over_budget = [], []
top_spend, top_pct = [], []

for kh in hashes:
    if not isinstance(kh, str): continue
    url = "{}/key/info?key={}".format(base_url.rstrip("/"), kh)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            info_raw = json.loads(resp.read())
    except Exception:
        continue

    info = info_raw.get("info") or info_raw
    if not isinstance(info, dict): continue

    k = info
    scanned += 1
    name = (k.get("key_alias") or k.get("key_name") or kh[:12] + "...")

    mb_raw = k.get("max_budget")
    sp_raw = k.get("spend") or 0
    try: sp = float(sp_raw)
    except (TypeError, ValueError): sp = 0.0
    try: mb = float(mb_raw) if mb_raw is not None else None
    except (TypeError, ValueError): mb = None
    if mb is not None and mb > 0: with_budget += 1
    if sp > 0: with_spend += 1

    entry = {"name": name, "spend": round(sp, 6), "max_budget": mb}
    # Ungoverned key: no max_budget set
    if not mb or mb <= 0:
        no_budget.append(entry)
    else:
        pct = round(100.0 * sp / mb, 2)
        entry["pct"] = pct
        if sp >= mb:
            over_budget.append(entry)
        elif pct >= 90.0:
            near_budget.append(entry)
    top_spend.append(entry)

    # Spend anomaly alert
    if spend_alert > 0 and sp >= spend_alert:
        entry["spend_alert_threshold"] = spend_alert
        high_spend.append(entry)

    # Budget reset
    reset_at = k.get("budget_reset_at")
    budget_duration = k.get("budget_duration")
    if reset_at and mb and mb > 0:
        entry["budget_reset_at"] = reset_at
        entry["budget_duration"] = budget_duration
        reset_dt = iso(reset_at)
        if reset_dt and reset_dt < now + timedelta(hours=soon_h):
            entry["budget_resets_in_h"] = round((reset_dt - now).total_seconds() / 3600, 1)
            budget_reset_soon.append(entry)

    exp_dt = iso(k.get("expires"))
    if exp_dt:
        if exp_dt < now:
            entry["expires"] = k.get("expires")
            expired.append(entry)
        elif exp_dt < soon:
            entry["expires"] = k.get("expires")
            expiring_soon.append(entry)

top_spend.sort(key=lambda e: -e["spend"])
top_pct = sorted((e for e in top_spend if e.get("pct") is not None),
                 key=lambda e: -e["pct"])

print(json.dumps({
    "scanned": scanned,
    "total_count": total_hashes,
    "with_budget": with_budget,
    "with_spend": with_spend,
    "no_budget": no_budget,
    "high_spend": high_spend,
    "budget_reset_soon": budget_reset_soon,
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
TOTAL_COUNT=$(jq -r '.total_count // "N/A"' <<<"$REPORT")
WITH_BUDGET=$(jq -r '.with_budget' <<<"$REPORT")
WITH_SPEND=$(jq -r '.with_spend' <<<"$REPORT")
NO_BUDGET=$(jq -r '.no_budget | length' <<<"$REPORT")
HIGH_SPEND=$(jq -r '.high_spend | length' <<<"$REPORT")
RESET_SOON=$(jq -r '.budget_reset_soon | length' <<<"$REPORT")
NEAR=$(jq -r '.near_budget | length' <<<"$REPORT")
OVER=$(jq -r '.over_budget | length' <<<"$REPORT")
EXPIRED=$(jq -r '.expired | length' <<<"$REPORT")
SOON=$(jq -r '.expiring_soon | length' <<<"$REPORT")

echo "Key inventory on \`${SVC}\`:"
echo "  scanned=${SCANNED} with_max_budget=${WITH_BUDGET} no_max_budget=${NO_BUDGET} with_recorded_spend=${WITH_SPEND}"
echo "  over_budget=${OVER} near_budget(>=90%)=${NEAR} high_spend(>=${SPEND_ALERT})=${HIGH_SPEND} expired=${EXPIRED} expiring_within_${EXPIRY_SOON_H}h=${SOON} budget_reset_soon=${RESET_SOON}"

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

if [[ "$NO_BUDGET" -gt 0 ]]; then
  names=$(jq -r '[.no_budget[].name] | join(", ")' <<<"$REPORT")
  details_json=$(jq -c '.no_budget' <<<"$REPORT")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Ungoverned key(s) — no max_budget set on \`${SVC}\`" \
    --arg details "${NO_BUDGET} key(s) have no max_budget configured: ${names}. Spend breakdown: ${details_json}" \
    --argjson severity 4 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Set max_budget on these keys to enable spend governance and budget alerts." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

if [[ "$HIGH_SPEND" -gt 0 ]]; then
  names=$(jq -r '[.high_spend[].name] | join(", ")' <<<"$REPORT")
  details_json=$(jq -c '.high_spend' <<<"$REPORT")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Key(s) with unusual spend on \`${SVC}\`" \
    --arg details "${HIGH_SPEND} key(s) exceeded LITELLM_KEY_SPEND_ALERT_USD=${SPEND_ALERT}: ${names}. Breakdown: ${details_json}" \
    --argjson severity 3 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Review spend patterns on these keys. Increase LITELLM_KEY_SPEND_ALERT_USD to adjust threshold (0 disables)." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

if [[ "$RESET_SOON" -gt 0 ]]; then
  names=$(jq -r '[.budget_reset_soon[].name] | join(", ")' <<<"$REPORT")
  details_json=$(jq -c '.budget_reset_soon' <<<"$REPORT")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Budget reset(s) approaching on \`${SVC}\`" \
    --arg details "${RESET_SOON} key(s) have a budget reset within ${EXPIRY_SOON_H}h: ${names}. Breakdown: ${details_json}" \
    --argjson severity 4 \
    --arg reproduce_hint "./inspect-litellm-key-budgets.sh" \
    --arg next_steps "Budget reset will replenish spend allowance. Verify keys are not at risk of exceeding budget before reset." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')

ISSUE_COUNT=$(jq 'length' <<<"$issues_json")
echo "Emitting ${ISSUE_COUNT} issue(s) from key inventory."

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
