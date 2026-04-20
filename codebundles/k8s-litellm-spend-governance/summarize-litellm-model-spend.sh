#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Produces per-model and per-user spend/usage summaries from OSS LiteLLM
# endpoints. Complements the k8s-litellm-proxy-health bundle (which only
# LISTS models and checks upstream health) by focusing on *governance*
# questions:
#
#   * Which models are driving spend in the current window?
#   * Which users are driving spend in the current window?
#   * Does any single model exceed LITELLM_MODEL_SPEND_THRESHOLD_USD?
#   * Does any single user exceed LITELLM_USER_SPEND_THRESHOLD_USD?
#
# Data sources (OSS, compact payloads, no enterprise license required):
#   * GET /spend/logs?summarize=true  -> per-user + per-model spend totals
#   * GET /global/activity/model      -> per-model request / token counts
#
# The summarized /spend/logs view returns ~1-2 KB regardless of traffic
# volume, so it does not have the port-forward payload-cap problem that
# summarize=false has on busy proxies.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"
litellm_init_runtime

OUTPUT_FILE="model_spend_issues.json"
issues_json='[]'
SVC="${LITELLM_SERVICE_NAME:-litellm}"
MODEL_THRESH="${LITELLM_MODEL_SPEND_THRESHOLD_USD:-0}"
USER_THRESH="${LITELLM_USER_SPEND_THRESHOLD_USD:-0}"
TOP_N="${LITELLM_TOP_N:-5}"
read -r START_DATE END_DATE <<<"$(litellm_date_range)"
TMP_SUM=$(mktemp)
TMP_ACT=$(mktemp)
litellm_register_cleanup 'rm -f "$TMP_SUM" "$TMP_ACT"'

# --- 1. Spend summary (per-user + per-model) --------------------------------
HTTP_SUM=$(litellm_get_file "/spend/logs?start_date=${START_DATE}&end_date=${END_DATE}&summarize=true" "$TMP_SUM" || echo "000")
echo "GET /spend/logs?summarize=true -> HTTP ${HTTP_SUM}"

if [[ "$HTTP_SUM" != "200" ]]; then
  reason=$(litellm_classify_spend_failure "$HTTP_SUM" "$TMP_SUM")
  case "$reason" in
    enterprise-gated|db-not-connected)
      echo "Skipping model spend summary: ${reason} (OSS informational)."
      echo '[]' >"$OUTPUT_FILE"
      exit 0
      ;;
    *)
      body=$(head -c 400 "$TMP_SUM" 2>/dev/null || true)
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot summarize LiteLLM model spend for \`${SVC}\`" \
        --arg details "GET /spend/logs?summarize=true returned HTTP ${HTTP_SUM} (classifier: ${reason}). Body: ${body}" \
        --argjson severity 2 \
        --arg reproduce_hint "./summarize-litellm-model-spend.sh" \
        --arg next_steps "Run check-litellm-spend-config.sh to confirm DB/auth state; rerun after fixing." \
        '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
      echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
      exit 0
      ;;
  esac
fi

# Aggregate per-model + per-user spend across the daily rollup rows.
SUMMARY_JSON=$(python3 - "$TMP_SUM" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    rows = json.load(f) or []
models = {}
users = {}
for row in rows if isinstance(rows, list) else []:
    for m, v in (row.get("models") or {}).items():
        try: models[m] = models.get(m, 0.0) + float(v)
        except (TypeError, ValueError): pass
    for u, v in (row.get("users") or {}).items():
        try: users[u] = users.get(u, 0.0) + float(v)
        except (TypeError, ValueError): pass
def top(d, n):
    return sorted([{"name": k, "spend_usd": round(v, 6)} for k, v in d.items() if v > 0],
                  key=lambda x: -x["spend_usd"])[:n]
print(json.dumps({
    "total_spend_usd": round(sum(models.values()), 6),
    "total_users": sum(1 for v in users.values() if v > 0),
    "total_models": sum(1 for v in models.values() if v > 0),
    "top_models": top(models, 50),
    "top_users": top(users, 50),
}))
PY
)
TOTAL_SPEND=$(jq -r '.total_spend_usd' <<<"$SUMMARY_JSON")
N_MODELS=$(jq -r '.total_models' <<<"$SUMMARY_JSON")
N_USERS=$(jq -r '.total_users' <<<"$SUMMARY_JSON")

echo "Spend summary (${START_DATE}..${END_DATE}):"
echo "  total_spend_usd=${TOTAL_SPEND} models=${N_MODELS} users=${N_USERS}"
echo "  top ${TOP_N} models by spend:"
jq -r --argjson n "$TOP_N" '.top_models[:$n] | .[] | "    " + .name + " = $" + (.spend_usd|tostring)' <<<"$SUMMARY_JSON"
echo "  top ${TOP_N} users by spend:"
jq -r --argjson n "$TOP_N" '.top_users[:$n] | .[] | "    " + .name + " = $" + (.spend_usd|tostring)' <<<"$SUMMARY_JSON"

# --- 2. Activity (per-model request / token volumes) ------------------------
HTTP_ACT=$(litellm_get_file "/global/activity/model?start_date=${START_DATE}&end_date=${END_DATE}" "$TMP_ACT" || echo "000")
ACTIVITY_SUMMARY=""
if [[ "$HTTP_ACT" == "200" ]]; then
  ACTIVITY_SUMMARY=$(jq -r --argjson n "$TOP_N" '
    [ .[] | {model, req: (.sum_api_requests // 0), tok: (.sum_total_tokens // 0)} ]
    | sort_by(-.req) | .[:$n] | .[]
    | "    " + .model + " req=" + (.req|tostring) + " tokens=" + (.tok|tostring)
  ' "$TMP_ACT" 2>/dev/null || true)
  echo "  top ${TOP_N} models by request volume:"
  printf '%s\n' "$ACTIVITY_SUMMARY"
else
  echo "  (activity endpoint unavailable: HTTP ${HTTP_ACT})"
fi

# --- 3. Threshold-based issues ----------------------------------------------
if awk -v t="$MODEL_THRESH" 'BEGIN{exit !(t>0)}'; then
  OFFENDERS=$(jq -c --argjson t "$MODEL_THRESH" '[.top_models[] | select(.spend_usd > $t)]' <<<"$SUMMARY_JSON")
  count=$(jq 'length' <<<"$OFFENDERS")
  if [[ "$count" -gt 0 ]]; then
    names=$(jq -r '[.[].name] | join(", ")' <<<"$OFFENDERS")
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Model(s) exceed per-model spend threshold on \`${SVC}\`" \
      --arg details "In window ${START_DATE}..${END_DATE} the following model group(s) exceeded LITELLM_MODEL_SPEND_THRESHOLD_USD=${MODEL_THRESH}: ${names}. Breakdown: $(echo "$OFFENDERS" | jq -c .)" \
      --argjson severity 3 \
      --arg reproduce_hint "./summarize-litellm-model-spend.sh" \
      --arg next_steps "Inspect callers of the offending model(s), consider routing heavy traffic to a cheaper model or adding per-key model_max_budget caps." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  fi
fi

if awk -v t="$USER_THRESH" 'BEGIN{exit !(t>0)}'; then
  OFFENDERS=$(jq -c --argjson t "$USER_THRESH" '[.top_users[] | select(.spend_usd > $t)]' <<<"$SUMMARY_JSON")
  count=$(jq 'length' <<<"$OFFENDERS")
  if [[ "$count" -gt 0 ]]; then
    names=$(jq -r '[.[].name] | join(", ")' <<<"$OFFENDERS")
    issues_json=$(echo "$issues_json" | jq \
      --arg title "User(s) exceed per-user spend threshold on \`${SVC}\`" \
      --arg details "In window ${START_DATE}..${END_DATE} the following user(s) exceeded LITELLM_USER_SPEND_THRESHOLD_USD=${USER_THRESH}: ${names}. Breakdown: $(echo "$OFFENDERS" | jq -c .)" \
      --argjson severity 3 \
      --arg reproduce_hint "./summarize-litellm-model-spend.sh" \
      --arg next_steps "Review user activity, adjust per-user max_budget / rpm_limit, and confirm team quotas are in place." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  fi
fi

ISSUE_COUNT=$(echo "$issues_json" | jq 'length')
if [[ "$ISSUE_COUNT" -eq 0 ]]; then
  if awk -v mt="$MODEL_THRESH" -v ut="$USER_THRESH" 'BEGIN{exit !(mt==0 && ut==0)}'; then
    echo "LITELLM_MODEL_SPEND_THRESHOLD_USD=0 and LITELLM_USER_SPEND_THRESHOLD_USD=0 — reporting breakdowns only, no issues raised."
  else
    echo "No model or user exceeds configured thresholds (model=${MODEL_THRESH} USD, user=${USER_THRESH} USD)."
  fi
else
  echo "Emitting ${ISSUE_COUNT} issue(s) from per-model/per-user spend summary."
fi
echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
