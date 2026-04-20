#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Summarizes failure / exception rates across LiteLLM model deployments using
# OSS-compatible endpoints. Previously this task pulled /spend/logs with
# summarize=false which on a busy proxy can return >100 MB and drop through a
# port-forward tunnel (HTTP 000). The new approach uses:
#
#   * GET /global/activity                        -> total request counts
#   * GET /global/activity/model                  -> list of active models
#   * GET /global/activity/exceptions/deployment  -> exceptions per model
#
# All three are OSS endpoints, return compact JSON, and don't require
# enterprise licensing. Results are aggregated into a single issue if the
# exception rate over the window exceeds LITELLM_EXCEPTION_RATE_PCT (default 1).
#
# If the activity endpoints are unreachable the task consults
# /health/readiness so the emitted issue accurately distinguishes between
# "no spend DB" (info, not a real failure) and "DB connected but endpoint
# failing" (warning).
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"
litellm_init_runtime

OUTPUT_FILE="aggregate_failure_issues.json"
issues_json='[]'
SVC="${LITELLM_SERVICE_NAME:-litellm}"
THRESH_PCT="${LITELLM_EXCEPTION_RATE_PCT:-1}"
read -r START_DATE END_DATE <<<"$(litellm_date_range)"

TMP_ACT=$(mktemp)
TMP_MOD=$(mktemp)
TMP_EX=$(mktemp)
litellm_register_cleanup 'rm -f "$TMP_ACT" "$TMP_MOD" "$TMP_EX"'

# --- 1. Total activity -------------------------------------------------------
HTTP_ACT=$(litellm_get_file "/global/activity?start_date=${START_DATE}&end_date=${END_DATE}" "$TMP_ACT" || echo "000")
echo "GET /global/activity -> HTTP ${HTTP_ACT}"

if [[ "$HTTP_ACT" != "200" ]]; then
  reason=$(litellm_classify_spend_failure "$HTTP_ACT" "$TMP_ACT")
  case "$reason" in
    enterprise-gated|db-not-connected)
      echo "aggregate: /global/activity unavailable (${reason}); skipping deep counts."
      echo '[]' >"$OUTPUT_FILE"
      exit 0
      ;;
    *)
      body=$(head -c 400 "$TMP_ACT" 2>/dev/null || true)
      issues_json=$(echo "$issues_json" | jq \
        --arg title "LiteLLM activity endpoint unavailable for \`${SVC}\`" \
        --arg details "GET /global/activity returned HTTP ${HTTP_ACT} (classifier: ${reason}). Body: ${body}" \
        --argjson severity 2 \
        --arg reproduce_hint "./aggregate-litellm-failure-signals.sh" \
        --arg next_steps "Check Pod logs, confirm spend DB is backing /global/activity, and verify admin auth." \
        '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
      echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
      exit 0
      ;;
  esac
fi

TOTAL_REQ=$(jq -r '.sum_api_requests // 0' "$TMP_ACT" 2>/dev/null || echo 0)
TOTAL_TOK=$(jq -r '.sum_total_tokens // 0' "$TMP_ACT" 2>/dev/null || echo 0)
echo "Total in window ${START_DATE}..${END_DATE}: requests=${TOTAL_REQ} tokens=${TOTAL_TOK}"

if [[ "${TOTAL_REQ:-0}" -eq 0 ]]; then
  echo "No request activity in window; nothing to aggregate."
  echo '[]' >"$OUTPUT_FILE"
  exit 0
fi

# --- 2. Per-model activity (to drive exception iteration) --------------------
HTTP_MOD=$(litellm_get_file "/global/activity/model?start_date=${START_DATE}&end_date=${END_DATE}" "$TMP_MOD" || echo "000")
echo "GET /global/activity/model -> HTTP ${HTTP_MOD}"

if [[ "$HTTP_MOD" != "200" ]]; then
  body=$(head -c 400 "$TMP_MOD" 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM per-model activity unavailable for \`${SVC}\`" \
    --arg details "GET /global/activity/model returned HTTP ${HTTP_MOD}. Body: ${body}" \
    --argjson severity 2 \
    --arg reproduce_hint "./aggregate-litellm-failure-signals.sh" \
    --arg next_steps "Check proxy logs and spend DB connectivity." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  exit 0
fi

# Enumerate model groups sorted by request count (top-N for iteration).
MAX_MODELS="${LITELLM_AGGREGATE_MAX_MODELS:-8}"
MODELS=$(jq -r --argjson n "$MAX_MODELS" '
  [ .[] | {model: .model, req: (.sum_api_requests // 0)} ]
  | sort_by(-.req) | .[:$n] | .[] | .model
' "$TMP_MOD" 2>/dev/null || true)

if [[ -z "$MODELS" ]]; then
  echo "No models found in activity response; nothing to aggregate."
  echo '[]' >"$OUTPUT_FILE"
  exit 0
fi

# --- 3. Per-model exceptions -------------------------------------------------
TOTAL_EX=0
PER_MODEL_SUMMARY=""
OFFENDERS=""
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  # URL-encode model group (basic — replace spaces and slashes).
  m_enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$m")
  code=$(litellm_get_file "/global/activity/exceptions/deployment?start_date=${START_DATE}&end_date=${END_DATE}&model_group=${m_enc}" "$TMP_EX" || echo "000")
  if [[ "$code" == "200" ]]; then
    model_ex=$(jq -r '[.[]?.sum_num_exceptions // 0] | add // 0' "$TMP_EX" 2>/dev/null || echo 0)
  else
    model_ex=0
    echo "  (skipping ${m}: exceptions endpoint HTTP ${code})"
  fi
  TOTAL_EX=$(( TOTAL_EX + model_ex ))
  PER_MODEL_SUMMARY+="  ${m}: exceptions=${model_ex}"$'\n'
  if [[ "${model_ex:-0}" -gt 0 ]]; then
    OFFENDERS+="${m}=${model_ex},"
  fi
done <<<"$MODELS"

OFFENDERS="${OFFENDERS%,}"
RATE_PCT=$(awk -v e="$TOTAL_EX" -v r="$TOTAL_REQ" 'BEGIN{ if(r>0) printf "%.3f", (e*100.0/r); else print "0.000" }')
echo "Aggregate: total_requests=${TOTAL_REQ} total_exceptions=${TOTAL_EX} exception_rate=${RATE_PCT}%"
echo "Per-model exception counts:"
printf '%s' "$PER_MODEL_SUMMARY"

if awk -v r="$RATE_PCT" -v t="$THRESH_PCT" 'BEGIN{exit !(r>t)}'; then
  severity=3
  # Escalate if rate is much higher than threshold.
  if awk -v r="$RATE_PCT" -v t="$THRESH_PCT" 'BEGIN{exit !(r > t*5)}'; then
    severity=2
  fi
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Elevated LiteLLM exception rate on \`${SVC}\`" \
    --arg details "Over ${START_DATE}..${END_DATE} the proxy served ${TOTAL_REQ} requests with ${TOTAL_EX} exceptions (${RATE_PCT}%); threshold LITELLM_EXCEPTION_RATE_PCT=${THRESH_PCT}%. Offenders: ${OFFENDERS:-<none>}." \
    --argjson severity "$severity" \
    --arg reproduce_hint "./aggregate-litellm-failure-signals.sh" \
    --arg next_steps "Inspect per-model health via the k8s-litellm-proxy-health bundle, check provider quotas, and look at LITELLM deployment logs for 5xx / rate-limit patterns." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

ISSUE_COUNT=$(jq 'length' <<<"$issues_json")
if [[ "$ISSUE_COUNT" -eq 0 ]]; then
  echo "Exception rate (${RATE_PCT}%) is at or below threshold ${THRESH_PCT}%; no issues raised."
else
  echo "Emitting ${ISSUE_COUNT} issue(s) from failure-signal aggregation."
fi
echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
