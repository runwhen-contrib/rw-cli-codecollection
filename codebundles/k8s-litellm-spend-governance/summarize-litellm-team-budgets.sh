#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Calls /team/info for configured team ids and reports a per-team spend/budget
# snapshot to stdout so the runbook report includes context even when no issue
# is raised. Raises severity 2 when spend is at or above max_budget, severity 3
# when spend is within 10% of max_budget, and severity 2 when the team is
# `blocked`.
#
# Skipped entirely when LITELLM_TEAM_IDS is empty (prints a helpful explainer
# so operators know how to enable this task).
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"

OUTPUT_FILE="team_budget_issues.json"
SVC="${LITELLM_SERVICE_NAME:-litellm}"

IDS="${LITELLM_TEAM_IDS:-}"
if [[ -z "${IDS// /}" ]]; then
  echo "LITELLM_TEAM_IDS is empty — skipping /team/info checks."
  echo "  This task inspects per-team budgets/limits for a curated list of team_ids."
  echo "  To enable it, set LITELLM_TEAM_IDS to a comma-separated list (e.g. \"platform,data-science\")."
  echo "  No issues will be raised by this task while LITELLM_TEAM_IDS is unset."
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
echo "Team budget snapshot on \`${SVC}\`:"
for raw in "${ARR[@]}"; do
  tid=$(echo "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$tid" ]] && continue
  CHECKED=$((CHECKED+1))
  enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$tid")
  PATH_Q="/team/info?team_id=${enc}"
  HTTP_CODE=$(litellm_get_file "$PATH_Q" "$TMP" || echo "000")

  if [[ "$HTTP_CODE" == "403" ]]; then
    body_preview="$(head -c 200 "$TMP" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    echo "  ${tid}: HTTP 403 (body: ${body_preview:-<empty>})"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot read LiteLLM team info for \`${tid}\`" \
      --arg details "GET /team/info returned HTTP 403 (team routes may require admin). Body preview: ${body_preview:-<empty>}." \
      --argjson severity 2 \
      --arg reproduce_hint "./summarize-litellm-team-budgets.sh" \
      --arg next_steps "Use a master key or grant team read permissions." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
    continue
  fi
  if [[ "$HTTP_CODE" != "200" ]]; then
    body_preview="$(head -c 200 "$TMP" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
    reason=$(litellm_classify_spend_failure "$HTTP_CODE" "$TMP")
    echo "  ${tid}: HTTP ${HTTP_CODE} (${reason}) body=${body_preview:-<empty>}"
    issues_json=$(echo "$issues_json" | jq \
      --arg title "team/info request failed for \`${tid}\`" \
      --arg details "GET /team/info returned HTTP ${HTTP_CODE} (classifier: ${reason}). Body preview: ${body_preview:-<empty>}." \
      --argjson severity 2 \
      --arg reproduce_hint "./summarize-litellm-team-budgets.sh" \
      --arg next_steps "Verify team_id and proxy version." \
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
if isinstance(o, dict) and isinstance(o.get("team_info"), dict):
    base = o["team_info"]
if not isinstance(base, dict):
    print(json.dumps({"error": "unexpected shape"})); raise SystemExit
def num(v):
    try: return float(v)
    except (TypeError, ValueError): return None
spend = num(base.get("spend")) or 0.0
max_budget = num(base.get("max_budget"))
rpm = base.get("rpm_limit") or base.get("rpm")
tpm = base.get("tpm_limit") or base.get("tpm")
blocked = bool(base.get("blocked"))
alias = base.get("team_alias") or base.get("alias") or ""
members = base.get("members") or base.get("members_with_roles") or []
try: member_count = len(members) if isinstance(members, list) else 0
except Exception: member_count = 0
models = base.get("models") or []
try: model_count = len(models) if isinstance(models, list) else 0
except Exception: model_count = 0
pct = (100.0 * spend / max_budget) if (max_budget and max_budget > 0) else None
print(json.dumps({
    "alias": alias,
    "spend": round(spend, 6),
    "max_budget": max_budget,
    "pct": round(pct, 2) if pct is not None else None,
    "rpm": rpm, "tpm": tpm,
    "blocked": blocked,
    "member_count": member_count,
    "model_count": model_count,
}))
PY
)
  if ! echo "$SNAPSHOT" | jq -e . >/dev/null 2>&1; then
    echo "  ${tid}: OK but response was unparseable"
    continue
  fi
  ALIAS=$(jq -r '.alias // ""' <<<"$SNAPSHOT")
  SPEND=$(jq -r '.spend' <<<"$SNAPSHOT")
  MAX=$(jq -r '.max_budget // "<none>"' <<<"$SNAPSHOT")
  PCT=$(jq -r '.pct // "-"' <<<"$SNAPSHOT")
  RPM=$(jq -r '.rpm // "<none>"' <<<"$SNAPSHOT")
  TPM=$(jq -r '.tpm // "<none>"' <<<"$SNAPSHOT")
  BLOCKED=$(jq -r '.blocked' <<<"$SNAPSHOT")
  MEMBERS=$(jq -r '.member_count' <<<"$SNAPSHOT")
  MODELS=$(jq -r '.model_count' <<<"$SNAPSHOT")
  echo "  ${tid}${ALIAS:+ (${ALIAS})}: spend=\$${SPEND} max_budget=\$${MAX} (${PCT}%) rpm=${RPM} tpm=${TPM} blocked=${BLOCKED} members=${MEMBERS} models=${MODELS}"

  if [[ "$BLOCKED" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Team \`${tid}\` is blocked on \`${SVC}\`" \
      --arg details "Team reports blocked=true via /team/info; all requests under this team will be rejected at the proxy." \
      --argjson severity 2 \
      --arg reproduce_hint "./summarize-litellm-team-budgets.sh" \
      --arg next_steps "Unblock via the admin UI/API after confirming budget posture." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  fi
  OVER_FLAG=$(jq -r 'if (.max_budget // 0) > 0 and .spend >= .max_budget then "true" else "false" end' <<<"$SNAPSHOT")
  NEAR_FLAG=$(jq -r 'if (.max_budget // 0) > 0 and .spend >= (.max_budget * 0.9) and .spend < .max_budget then "true" else "false" end' <<<"$SNAPSHOT")
  if [[ "$OVER_FLAG" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Team \`${tid}\` is at or over max_budget on \`${SVC}\`" \
      --arg details "spend=\$${SPEND} >= max_budget=\$${MAX} (${PCT}%). Team requests may be rejected." \
      --argjson severity 2 \
      --arg reproduce_hint "./summarize-litellm-team-budgets.sh" \
      --arg next_steps "Raise team max_budget, reduce traffic, or shift consumption to cheaper models." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  elif [[ "$NEAR_FLAG" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Team \`${tid}\` near max_budget on \`${SVC}\`" \
      --arg details "spend=\$${SPEND} at ${PCT}% of max_budget=\$${MAX}." \
      --argjson severity 3 \
      --arg reproduce_hint "./summarize-litellm-team-budgets.sh" \
      --arg next_steps "Raise team budget, reduce traffic, or add models with lower cost." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  fi
done

echo "Scanned ${CHECKED} team_id(s); ${OK} returned HTTP 200."
ISSUE_COUNT=$(jq 'length' <<<"$issues_json")
echo "Emitting ${ISSUE_COUNT} issue(s) from team budget summary."
echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote $OUTPUT_FILE"
