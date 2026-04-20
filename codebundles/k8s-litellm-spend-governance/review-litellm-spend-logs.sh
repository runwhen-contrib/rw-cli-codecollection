#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Scans LiteLLM spend logs for failure and budget-related signals.
#
# Strategy (OSS-aware and payload-aware):
#   1. Pull the summarized view first  — /spend/logs?summarize=true — which
#      returns per-user and per-model spend totals in ~1-2 KB regardless of
#      log volume. This is a robust "is the spend DB working?" signal even
#      on busy proxies with multi-MB raw logs.
#   2. Only if summarize=true succeeds AND the total spend is meaningful,
#      attempt the raw /spend/logs?summarize=false view for row-level heuristics.
#      On busy proxies this response can be >100 MB and may drop through
#      a kubectl port-forward tunnel — handled gracefully.
#   3. When any /spend/logs call fails, consult /health/readiness (via the
#      litellm_classify_spend_failure helper) so the emitted issue says
#      "DB connected but response dropped" vs. "no DB configured" accurately.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"
litellm_init_runtime

OUTPUT_FILE="spend_logs_issues.json"
issues_json='[]'
SVC="${LITELLM_SERVICE_NAME:-litellm}"
read -r START_DATE END_DATE <<<"$(litellm_date_range)"
TMP=$(mktemp)
TMP_RAW=$(mktemp)
litellm_register_cleanup 'rm -f "$TMP" "$TMP_RAW"'

emit_no_db_info() {
  # Informational only — absent DB is a valid OSS configuration.
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Spend logs unavailable for \`${SVC}\` (no DB backing)" \
    --arg details "GET /spend/logs is not returning data and /health/readiness reports db=\"${_LITELLM_DB_STATUS:-unknown}\". Without a spend-tracking DB configured, log-based governance is not possible on this proxy." \
    --argjson severity 1 \
    --arg reproduce_hint "./review-litellm-spend-logs.sh" \
    --arg next_steps "If you want log-based governance alerts, configure LiteLLM with a database (Postgres recommended) via LITELLM_DATABASE_URL and enable store_model_in_db. See https://docs.litellm.ai/docs/proxy/db_info." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
}

emit_transient() {
  local phase="$1"
  local code="$2"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM spend logs transiently unavailable on \`${SVC}\`" \
    --arg details "GET /spend/logs (${phase}) returned HTTP ${code} but /health/readiness reports db=connected. Most common cause on a busy proxy is the unsummarized response being too large to stream through the kubectl port-forward tunnel within the configured timeout (LITELLM_MAX_TIME=${LITELLM_MAX_TIME:-20}s)." \
    --argjson severity 2 \
    --arg reproduce_hint "./review-litellm-spend-logs.sh" \
    --arg next_steps "Retry with a narrower RW_LOOKBACK_WINDOW, rely on the summarize=true rollup (already used by this task), or query LiteLLM directly from inside the cluster to avoid the port-forward payload cap." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
}

# --- 1. Summarized view (cheap, OSS-friendly) ---------------------------------
PATH_SUM="/spend/logs?start_date=${START_DATE}&end_date=${END_DATE}&summarize=true"
HTTP_SUM=$(litellm_get_file "$PATH_SUM" "$TMP" || echo "000")
echo "GET ${PATH_SUM} -> HTTP ${HTTP_SUM}"

if [[ "$HTTP_SUM" == "403" || "$HTTP_SUM" == "401" ]]; then
  body=$(head -c 400 "$TMP" 2>/dev/null || true)
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM spend logs access denied for \`${SVC}\`" \
    --arg details "GET ${PATH_SUM} returned HTTP ${HTTP_SUM}. The current key lacks spend route permissions. Body (truncated): ${body}" \
    --argjson severity 2 \
    --arg reproduce_hint "./review-litellm-spend-logs.sh" \
    --arg next_steps "Supply the master key via litellm_master_key (or a key with get_spend_routes / admin scope)." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  echo "Wrote ${OUTPUT_FILE} (auth denied on summarize=true)"
  exit 0
fi

if [[ "$HTTP_SUM" != "200" ]]; then
  reason=$(litellm_classify_spend_failure "$HTTP_SUM" "$TMP")
  case "$reason" in
    enterprise-gated)
      echo "/spend/logs is enterprise-gated on this proxy; nothing to scan (OSS mode)."
      echo '[]' >"$OUTPUT_FILE"
      exit 0
      ;;
    db-not-connected)
      echo "/spend/logs HTTP ${HTTP_SUM} and /health/readiness reports db=${_LITELLM_DB_STATUS:-unknown}; emitting informational."
      emit_no_db_info
      echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
      echo "Wrote ${OUTPUT_FILE} (no-DB informational)"
      exit 0
      ;;
    transient-tunnel-or-timeout|db-connected-endpoint-error|unknown-readiness-unreachable)
      echo "/spend/logs HTTP ${HTTP_SUM}; DB appears connected — marking transient."
      emit_transient "summarize=true" "$HTTP_SUM"
      echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
      echo "Wrote ${OUTPUT_FILE} (transient)"
      exit 0
      ;;
    *)
      body=$(head -c 400 "$TMP" 2>/dev/null || true)
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot fetch LiteLLM spend log summary for \`${SVC}\`" \
        --arg details "HTTP ${HTTP_SUM} from ${PATH_SUM}. Classifier: ${reason}. Body (truncated): ${body}" \
        --argjson severity 2 \
        --arg reproduce_hint "./review-litellm-spend-logs.sh" \
        --arg next_steps "Verify PROXY_BASE_URL, that spend routes are enabled, and the proxy is healthy." \
        '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
      echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
      echo "Wrote ${OUTPUT_FILE} (${reason})"
      exit 0
      ;;
  esac
fi

# Parse the summary for a quick picture. Schema is
#   [ { users: { "<id>": <total_usd>, ... }, models: { "<name>": <total>, ... } }, ... ]
TOP_N="${LITELLM_TOP_N:-5}"
TOTAL_USERS=$(jq '[.[]?.users // {} | keys[]] | unique | length' "$TMP" 2>/dev/null || echo 0)
TOTAL_MODELS=$(jq '[.[]?.models // {} | keys[]] | unique | length' "$TMP" 2>/dev/null || echo 0)
TOTAL_SPEND=$(jq '[.[]?.users // {} | to_entries[] | .value] | add // 0' "$TMP" 2>/dev/null || echo 0)
DAY_COUNT=$(jq 'length' "$TMP" 2>/dev/null || echo 0)
echo "Spend log summary on \`${SVC}\` for ${START_DATE}..${END_DATE}:"
echo "  daily_rows=${DAY_COUNT} unique_users=${TOTAL_USERS} unique_models=${TOTAL_MODELS} total_spend_usd=${TOTAL_SPEND}"

echo "  top ${TOP_N} models by spend in window:"
jq -r --argjson n "$TOP_N" '
  [ .[]? | (.models // {}) | to_entries[] ]
  | group_by(.key) | map({model: .[0].key, spend: ([.[] | .value] | add // 0)})
  | sort_by(-.spend) | .[:$n]
  | .[] | "    " + .model + " = $" + (.spend|tostring)
' "$TMP" 2>/dev/null || true

echo "  top ${TOP_N} users by spend in window:"
jq -r --argjson n "$TOP_N" '
  [ .[]? | (.users // {}) | to_entries[] ]
  | group_by(.key) | map({user: .[0].key, spend: ([.[] | .value] | add // 0)})
  | sort_by(-.spend) | .[:$n]
  | .[] | "    " + (if .user == "" then "<anonymous>" else .user end) + " = $" + (.spend|tostring)
' "$TMP" 2>/dev/null || true

# Daily spend trajectory (up to 14 most recent days) so operators can spot a
# ramp-up in the report without needing to hit the API themselves. The
# /spend/logs?summarize=true rollup uses startTime as the day key and spend
# as the per-day total.
echo "  daily spend trajectory (most recent first, truncated to 14):"
jq -r '
  [ .[]? | {date: (.startTime // .date // .day // "?"), spend: (.spend // ([(.users // {}) | to_entries[] | .value] | add // 0))} ]
  | sort_by(.date) | reverse | .[:14]
  | .[] | "    " + (.date|tostring) + " = $" + (.spend|tostring)
' "$TMP" 2>/dev/null || true

# --- 2. Optional raw log scan for failure/budget keywords --------------------
# Disabled by default because on busy proxies /spend/logs?summarize=false can
# return >100 MB, which reliably drops through a kubectl port-forward tunnel
# (HTTP 000) and is not needed for the summary-level governance we care about
# here. The aggregate-litellm-failure-signals.sh task already gives us
# per-model exception counts via /global/activity/exceptions/deployment.
# Operators who want string-heuristic scanning can opt in by setting
# LITELLM_ENABLE_RAW_LOG_SCAN=true.
SUSPICIOUS=0
RAW_STATUS="skipped (LITELLM_ENABLE_RAW_LOG_SCAN not enabled)"
if [[ "${LITELLM_ENABLE_RAW_LOG_SCAN:-false}" == "true" ]] && awk -v s="$TOTAL_SPEND" 'BEGIN{exit !(s>0)}'; then
  PATH_RAW="/spend/logs?start_date=${START_DATE}&end_date=${END_DATE}&summarize=false"
  # Bound the raw scan hard so a multi-MB response cannot stall the task.
  _PREV_MAX_TIME="${LITELLM_MAX_TIME:-}"
  export LITELLM_MAX_TIME="${LITELLM_RAW_MAX_TIME:-15}"
  HTTP_RAW=$(litellm_get_file "$PATH_RAW" "$TMP_RAW" || echo "000")
  if [[ -n "$_PREV_MAX_TIME" ]]; then export LITELLM_MAX_TIME="$_PREV_MAX_TIME"; else unset LITELLM_MAX_TIME; fi
  echo "GET ${PATH_RAW} -> HTTP ${HTTP_RAW} ($(stat -c '%s' "$TMP_RAW" 2>/dev/null || echo '?') bytes)"
  if [[ "$HTTP_RAW" == "200" ]]; then
    SUSPICIOUS=$(jq -r '
      (if type == "array" then . else [] end)
      | map(tostring)
      | map(select(test("budget_exceeded|rate_limited|BudgetExceeded|RateLimitError|\"status\"\\s*:\\s*\"failure\"|Internal Server Error|\" 5\\d\\d \"|\" 429 \""; "i")))
      | length
    ' "$TMP_RAW" 2>/dev/null || echo 0)
    RAW_STATUS="scanned (${SUSPICIOUS} suspicious)"
  else
    RAW_STATUS="raw_scan_unavailable(HTTP ${HTTP_RAW}) — response likely too large for tunnel; see LITELLM_RAW_MAX_TIME"
  fi
fi

if [[ "${SUSPICIOUS:-0}" =~ ^[0-9]+$ ]] && [[ "${SUSPICIOUS}" -gt 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Spend logs show failures or budget/rate-limit signals for \`${SVC}\`" \
    --arg details "In window ${START_DATE}..${END_DATE} (${RW_LOOKBACK_WINDOW:-24h}), approximately ${SUSPICIOUS} raw log row(s) matched error/budget/rate-limit heuristics. Summary totals: users=${TOTAL_USERS} models=${TOTAL_MODELS} spend=${TOTAL_SPEND} USD." \
    --argjson severity 3 \
    --arg reproduce_hint "./review-litellm-spend-logs.sh" \
    --arg next_steps "Inspect proxy metrics and key/team budgets; review provider outages; confirm spend logs are complete." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

ISSUE_COUNT=$(jq 'length' <<<"$issues_json")
echo "Emitting ${ISSUE_COUNT} issue(s) from spend-log review."
echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}. raw_scan=${RAW_STATUS}"
