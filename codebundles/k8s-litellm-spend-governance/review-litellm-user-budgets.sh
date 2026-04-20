#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Calls /user/info for each LITELLM_USER_IDS entry and reports a per-user
# spend/budget snapshot to stdout so the runbook report includes context even
# when no issue is raised. Raises severity 3 when soft_budget_cooldown is
# observed, severity 2 when spend is at or above max_budget, severity 3 when
# spend is within 10% of max_budget.
#
# Skipped entirely when LITELLM_USER_IDS is empty (prints a helpful explainer
# so operators know how to enable this task).
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"

OUTPUT_FILE="user_budget_issues.json"
SVC="${LITELLM_SERVICE_NAME:-litellm}"

IDS="${LITELLM_USER_IDS:-}"
if [[ -z "${IDS// /}" ]]; then
  echo "LITELLM_USER_IDS is empty — skipping /user/info checks."
  echo "  This task inspects per-user budgets/limits for a curated list of internal user_ids."
  echo "  To enable it, set LITELLM_USER_IDS to a comma-separated list (e.g. \"alice,bob,ci-runner\")."
  echo "  No issues will be raised by this task while LITELLM_USER_IDS is unset."
  echo '[]' >"$OUTPUT_FILE"
  echo "Wrote empty $OUTPUT_FILE"
  exit 0
fi

litellm_init_runtime
issues_json='[]'
TMP=$(mktemp)
litellm_register_cleanup 'rm -f "$TMP"'

IFS=',' read -ra ARR <<<"$IDS"
CHECKED=0
OK=0
echo "User budget snapshot on \`${SVC}\`:"
for raw in "${ARR[@]}"; do
  uid=$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$uid" ]] && continue
  CHECKED=$((CHECKED+1))
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$uid")
  PATH_Q="/user/info?user_id=${enc}"
  HTTP_CODE=$(litellm_get_file "$PATH_Q" "$TMP" || echo "000")

  if [[ "$HTTP_CODE" == "403" ]]; then
    body_preview="$(head -c 200 "$TMP" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    echo "  ${uid}: HTTP 403 (body: ${body_preview:-<empty>})"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read LiteLLM user info for \`${uid}\`" \
      --arg details "GET /user/info returned HTTP 403. Body preview: ${body_preview:-<empty>}." \
      --argjson severity 2 \
      --arg reproduce_hint "./review-litellm-user-budgets.sh" \
      --arg next_steps "Grant user read permissions or use a master key with user admin scope." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
    continue
  fi

  if [[ "$HTTP_CODE" != "200" ]]; then
    body_preview="$(head -c 200 "$TMP" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    reason=$(litellm_classify_spend_failure "$HTTP_CODE" "$TMP")
    echo "  ${uid}: HTTP ${HTTP_CODE} (${reason}) body=${body_preview:-<empty>}"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "user/info request failed for \`${uid}\`" \
      --arg details "GET /user/info returned HTTP ${HTTP_CODE} (classifier: ${reason}). Body preview: ${body_preview:-<empty>}." \
      --argjson severity 2 \
      --arg reproduce_hint "./review-litellm-user-budgets.sh" \
      --arg next_steps "Verify user_id exists and PROXY_BASE_URL is correct." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
    continue
  fi
  OK=$((OK+1))

  SNAPSHOT=$(python3 - "$TMP" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        o = json.load(f)
except Exception:
    print(json.dumps({"error": "unparseable"})); raise SystemExit
base = o
if isinstance(o, dict) and isinstance(o.get("user_info"), dict):
    base = o["user_info"]
if not isinstance(base, dict):
    print(json.dumps({"error": "unexpected shape"})); raise SystemExit
def num(v):
    try: return float(v)
    except (TypeError, ValueError): return None
spend = num(base.get("spend")) or 0.0
max_budget = num(base.get("max_budget"))
soft_budget = num(base.get("soft_budget"))
rpm = base.get("rpm_limit") or base.get("rpm")
tpm = base.get("tpm_limit") or base.get("tpm")
cooldown = bool(base.get("soft_budget_cooldown"))
teams = base.get("teams") or base.get("team_ids") or []
if isinstance(teams, list):
    teams_s = ",".join(str(t) for t in teams[:5])
else:
    teams_s = str(teams)
pct = (100.0 * spend / max_budget) if (max_budget and max_budget > 0) else None
print(json.dumps({
    "spend": round(spend, 6),
    "max_budget": max_budget,
    "pct": round(pct, 2) if pct is not None else None,
    "soft_budget": soft_budget,
    "rpm": rpm, "tpm": tpm,
    "cooldown": cooldown,
    "teams": teams_s,
}))
PY
)
  if ! echo "$SNAPSHOT" | jq -e . >/dev/null 2>&1; then
    echo "  ${uid}: OK but response was unparseable"
    continue
  fi
  SPEND=$(jq -r '.spend' <<<"$SNAPSHOT")
  MAX=$(jq -r '.max_budget // "<none>"' <<<"$SNAPSHOT")
  PCT=$(jq -r '.pct // "-"' <<<"$SNAPSHOT")
  COOL=$(jq -r '.cooldown' <<<"$SNAPSHOT")
  SOFT=$(jq -r '.soft_budget // "<none>"' <<<"$SNAPSHOT")
  RPM=$(jq -r '.rpm // "<none>"' <<<"$SNAPSHOT")
  TPM=$(jq -r '.tpm // "<none>"' <<<"$SNAPSHOT")
  TEAMS=$(jq -r '.teams' <<<"$SNAPSHOT")
  echo "  ${uid}: spend=\$${SPEND} max_budget=\$${MAX} (${PCT}%) soft_budget=\$${SOFT} rpm=${RPM} tpm=${TPM} cooldown=${COOL} teams=${TEAMS:-<none>}"

  if [[ "$COOL" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "User \`${uid}\` is in soft budget cooldown on \`${SVC}\`" \
      --arg details "soft_budget_cooldown=true from /user/info. spend=\$${SPEND} soft_budget=\$${SOFT} max_budget=\$${MAX}." \
      --argjson severity 3 \
      --arg reproduce_hint "./review-litellm-user-budgets.sh" \
      --arg next_steps "Raise the user's budget, wait for cooldown, or shift traffic to another key/team." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  fi
  # Over / near max_budget (requires max_budget > 0)
  OVER_FLAG=$(jq -r 'if (.max_budget // 0) > 0 and .spend >= .max_budget then "true" else "false" end' <<<"$SNAPSHOT")
  NEAR_FLAG=$(jq -r 'if (.max_budget // 0) > 0 and .spend >= (.max_budget * 0.9) and .spend < .max_budget then "true" else "false" end' <<<"$SNAPSHOT")
  if [[ "$OVER_FLAG" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "User \`${uid}\` is at or over max_budget on \`${SVC}\`" \
      --arg details "spend=\$${SPEND} >= max_budget=\$${MAX} (${PCT}%). Requests for this user may be rejected." \
      --argjson severity 2 \
      --arg reproduce_hint "./review-litellm-user-budgets.sh" \
      --arg next_steps "Raise max_budget, rotate the user's keys, or move traffic to a team with headroom." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  elif [[ "$NEAR_FLAG" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "User \`${uid}\` is near max_budget on \`${SVC}\`" \
      --arg details "spend=\$${SPEND} at ${PCT}% of max_budget=\$${MAX}." \
      --argjson severity 3 \
      --arg reproduce_hint "./review-litellm-user-budgets.sh" \
      --arg next_steps "Monitor consumption and consider raising max_budget before overflow triggers 429s." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  fi
done

echo "Scanned ${CHECKED} user_id(s); ${OK} returned HTTP 200."
ISSUE_COUNT=$(jq 'length' <<<"$issues_json")
echo "Emitting ${ISSUE_COUNT} issue(s) from user budget review."
echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
