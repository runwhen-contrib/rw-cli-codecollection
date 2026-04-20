#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Reports the LiteLLM proxy's spend-tracking configuration as observed via
# /health/readiness. This is the authoritative OSS signal for:
#   * Is a database wired up?     (db == "connected")
#   * Is a cache wired up?        (cache field, e.g. "redis")
#   * Which success callbacks are loaded (DB logging, S3 logging, etc.)?
#
# It also performs a cheap sanity check on /key/list to confirm the admin API
# surface is reachable, since that is required for every other governance
# task in this codebundle.
#
# Rationale: before blaming "no DB" on HTTP 000 / 500 from /spend/logs we want
# a deterministic signal of DB presence, so runbook output is actionable
# (e.g. "/spend/logs timed out because the response is large, not because
# the DB is missing").
#
# Emits governance issues when:
#   sev 3 - DB is NOT connected (no spend tracking possible)
#   sev 2 - /health/readiness reports "status" other than "connected"
#   sev 3 - /key/list unreachable (admin auth or routing broken)
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=litellm-http-helpers.sh
source "${SCRIPT_DIR}/litellm-http-helpers.sh"
litellm_init_runtime

OUTPUT_FILE="spend_config_issues.json"
issues_json='[]'
SVC="${LITELLM_SERVICE_NAME:-litellm}"
NS="${NAMESPACE:-unknown}"
TMP=$(mktemp)
litellm_register_cleanup 'rm -f "$TMP"'

# --- 1. /health/readiness ----------------------------------------------------
if litellm_readiness; then
  READINESS_HTTP="$_LITELLM_READINESS_HTTP"
  DB="${_LITELLM_DB_STATUS:-unknown}"
  CACHE="${_LITELLM_CACHE_TYPE:-}"
  CALLBACKS="${_LITELLM_CALLBACKS:-}"
  STATUS="$(echo "${_LITELLM_READINESS_BODY:-}" | jq -r '.status // "unknown"' 2>/dev/null || echo unknown)"
  VERSION="$(echo "${_LITELLM_READINESS_BODY:-}" | jq -r '.litellm_version // "unknown"' 2>/dev/null || echo unknown)"
  echo "Readiness: HTTP ${READINESS_HTTP}"
  echo "  status=${STATUS}"
  echo "  db=${DB}"
  echo "  cache=${CACHE:-<none>}"
  echo "  litellm_version=${VERSION}"
  echo "  success_callbacks=${CALLBACKS:-<none>}"
else
  READINESS_HTTP="$_LITELLM_READINESS_HTTP"
  DB="${_LITELLM_DB_STATUS:-unknown}"
  CACHE=""
  CALLBACKS=""
  STATUS="unreachable"
  VERSION="unknown"
  body_preview="$(printf '%s' "${_LITELLM_READINESS_BODY:-}" | head -c 400 | tr -d '\r' | tr '\n' ' ')"
  echo "Readiness: HTTP ${READINESS_HTTP} (unhealthy). Body preview: ${body_preview:-<empty>}"
fi

# Emit issues based on what readiness told us.
if [[ "${READINESS_HTTP}" != "200" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM /health/readiness unreachable for \`${SVC}\`" \
    --arg details "GET /health/readiness returned HTTP ${READINESS_HTTP}. This endpoint is unauthenticated and included in every OSS build, so a non-200 indicates the proxy is not yet serving traffic, the port-forward failed, or a reverse proxy strips the /health route." \
    --argjson severity 3 \
    --arg reproduce_hint "./check-litellm-spend-config.sh" \
    --arg next_steps "Check Pod status in namespace \`${NS}\`, verify Service selector and port, and confirm no ingress strips /health/*." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
else
  if [[ "${DB}" != "connected" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "LiteLLM spend-tracking DB not connected on \`${SVC}\`" \
      --arg details "/health/readiness reports db=\"${DB}\". Without a connected database the proxy cannot persist /spend/logs, /spend/tags, or aggregate reports, so spend-governance checks that rely on historical data will be skipped." \
      --argjson severity 3 \
      --arg reproduce_hint "./check-litellm-spend-config.sh" \
      --arg next_steps "Configure LITELLM_DATABASE_URL (Postgres recommended) and enable store_model_in_db in the LiteLLM config, then restart the proxy. See https://docs.litellm.ai/docs/proxy/db_info." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  fi
  if [[ "${STATUS}" != "connected" && "${STATUS}" != "healthy" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "LiteLLM /health/readiness reports non-connected status on \`${SVC}\`" \
      --arg details "Readiness status field = \"${STATUS}\". Expected \"connected\" on a healthy proxy." \
      --argjson severity 2 \
      --arg reproduce_hint "./check-litellm-spend-config.sh" \
      --arg next_steps "Check LiteLLM Pod logs, upstream provider connectivity, and callback plugin initialization." \
      '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
  fi
fi

# --- 2. /key/list admin reachability ----------------------------------------
HTTP_CODE=$(litellm_get_file "/key/list?size=1" "$TMP" || echo "000")
echo "Admin API probe: GET /key/list?size=1 -> HTTP ${HTTP_CODE}"
if [[ "${HTTP_CODE}" != "200" ]]; then
  body_preview="$(head -c 400 "$TMP" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"
  reason="$(litellm_classify_spend_failure "$HTTP_CODE" "$TMP")"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM admin /key/list unreachable on \`${SVC}\`" \
    --arg details "GET /key/list returned HTTP ${HTTP_CODE} (classified: ${reason}). Response preview: ${body_preview:-<empty>}" \
    --argjson severity 3 \
    --arg reproduce_hint "./check-litellm-spend-config.sh" \
    --arg next_steps "Validate litellm_master_key, that the proxy enables /key routes, and that no gateway rewrites strip /key/*." \
    '. += [{title: $title, details: $details, severity: $severity, reproduce_hint: $reproduce_hint, next_steps: $next_steps}]')
fi

ISSUE_COUNT=$(echo "$issues_json" | jq 'length')
if [[ "$ISSUE_COUNT" -eq 0 ]]; then
  echo "Spend-tracking configuration looks healthy (DB connected, admin API reachable, readiness=200)."
else
  echo "Emitting ${ISSUE_COUNT} issue(s) from spend-config check."
fi
echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
