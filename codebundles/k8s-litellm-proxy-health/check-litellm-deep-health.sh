#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Optional GET /health — performs real upstream LLM calls; gated by LITELLM_RUN_DEEP_HEALTH.
#
# PROXY_BASE_URL is optional. When unset, kubectl port-forward is used against
# svc/${LITELLM_SERVICE_NAME} on ${LITELLM_HTTP_PORT}.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_FILE="${OUTPUT_FILE:-litellm_deep_health_issues.json}"
issues_json='[]'
MAX_TIME="${CURL_MAX_TIME:-45}"
RUN_DEEP="${LITELLM_RUN_DEEP_HEALTH:-false}"

if [[ "$RUN_DEEP" != "true" && "$RUN_DEEP" != "True" && "$RUN_DEEP" != "1" ]]; then
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  echo "Deep health skipped (LITELLM_RUN_DEEP_HEALTH is not true). Issues written to $OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_master_key_helper.sh"
ensure_proxy_base_url
resolve_master_key
BASE_URL="${PROXY_BASE_URL%/}"

if [[ -z "${LITELLM_MASTER_KEY:-}" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM deep health requires master key for \`${BASE_URL}\`" \
    --arg details "LITELLM_RUN_DEEP_HEALTH is enabled but LITELLM_MASTER_KEY is empty. GET /health requires Authorization per LiteLLM docs." \
    --argjson severity 3 \
    --arg next_steps "Import secret litellm_master_key or disable LITELLM_RUN_DEEP_HEALTH." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

tmpf=$(mktemp)
http_code=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Accept: application/json" \
  "${BASE_URL}/health" 2>/dev/null || echo "000")
body=$(cat "$tmpf" || true)
rm -f "$tmpf"
body_preview=$(printf '%s' "$body" | head -c 600 | tr -d '\r' | tr '\n' ' ')
echo "GET ${BASE_URL}/health -> HTTP ${http_code}"
[[ -n "$body_preview" ]] && echo "  body: ${body_preview}"

if [[ "$http_code" != "200" ]]; then
  echo "Result: deep health FAILED (HTTP ${http_code})."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM deep health HTTP error for \`${BASE_URL}\`" \
    --arg details "GET /health returned HTTP ${http_code}. Response (truncated): $(echo "$body" | head -c 800)" \
    --argjson severity 4 \
    --arg next_steps "Verify the master key, proxy logs, and upstream provider credentials." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

if echo "$body" | jq -e . >/dev/null 2>&1; then
  unhealthy=$(echo "$body" | jq '[.unhealthy_endpoints[]?] | length' 2>/dev/null || echo 0)
  healthy=$(echo "$body" | jq '[.healthy_endpoints[]?] | length' 2>/dev/null || echo 0)
  echo "Parsed: healthy_endpoints=${healthy} unhealthy_endpoints=${unhealthy}"
  if [[ "${unhealthy:-0}" -gt 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "LiteLLM reports unhealthy upstream endpoints for \`${BASE_URL}\`" \
      --arg details "$(echo "$body" | jq -c '{unhealthy_endpoints: .unhealthy_endpoints, healthy_endpoints: .healthy_endpoints}' 2>/dev/null || echo "$body")" \
      --argjson severity 3 \
      --arg next_steps "Inspect unhealthy_endpoints in the response, provider quotas, and network egress from the proxy." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
  fi
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Deep health check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
