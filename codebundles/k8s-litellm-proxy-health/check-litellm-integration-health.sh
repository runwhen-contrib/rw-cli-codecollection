#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# GET /health/services?service=... for named integrations (admin endpoint).
#
# PROXY_BASE_URL is optional. When unset, kubectl port-forward is used against
# svc/${LITELLM_SERVICE_NAME} on ${LITELLM_HTTP_PORT}.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_FILE="${OUTPUT_FILE:-litellm_integration_issues.json}"
issues_json='[]'
MAX_TIME="${CURL_MAX_TIME:-25}"
SERVICES="${LITELLM_INTEGRATION_SERVICES:-}"

if [[ -z "${SERVICES// /}" ]]; then
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  echo "Integration health skipped (LITELLM_INTEGRATION_SERVICES empty). Issues written to $OUTPUT_FILE"
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
    --arg title "LiteLLM integration health requires master key for \`${BASE_URL}\`" \
    --arg details "LITELLM_INTEGRATION_SERVICES is set but LITELLM_MASTER_KEY is empty." \
    --argjson severity 2 \
    --arg next_steps "Import secret litellm_master_key or clear LITELLM_INTEGRATION_SERVICES to skip this check." \
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

echo "Services to probe: ${SERVICES}"
IFS=',' read -ra ARR <<<"$SERVICES"
for raw in "${ARR[@]}"; do
  svc=$(echo "$raw" | xargs)
  [[ -z "$svc" ]] && continue
  tmpf=$(mktemp)
  http_code=$(curl -sS -G --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Accept: application/json" \
    --data-urlencode "service=${svc}" \
    "${BASE_URL}/health/services" 2>/dev/null || echo "000")
  body=$(cat "$tmpf" || true)
  rm -f "$tmpf"
  body_preview=$(printf '%s' "$body" | head -c 400 | tr -d '\r' | tr '\n' ' ')
  echo "GET ${BASE_URL}/health/services?service=${svc} -> HTTP ${http_code}"
  [[ -n "$body_preview" ]] && echo "  body: ${body_preview}"

  if [[ "$http_code" != "200" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Integration \`${svc}\` health request failed for \`${BASE_URL}\`" \
      --arg details "HTTP ${http_code}. Response (truncated): $(echo "$body" | head -c 500)" \
      --argjson severity 3 \
      --arg next_steps "Confirm the integration name matches LiteLLM configuration and the proxy can reach the integration." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
    continue
  fi

  if echo "$body" | jq -e . >/dev/null 2>&1; then
    unhealthy=$(echo "$body" | jq -r 'if .healthy == false then 1 elif .status? == "unhealthy" then 1 elif .error? then 1 else 0 end' 2>/dev/null || echo 0)
    if [[ "$unhealthy" == "1" ]]; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Integration \`${svc}\` unhealthy for \`${BASE_URL}\`" \
        --arg details "$(echo "$body" | jq -c . 2>/dev/null || echo "$body")" \
        --argjson severity 2 \
        --arg next_steps "Review integration configuration, credentials, and network access for ${svc}." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": $severity,
           "next_steps": $next_steps
         }]')
    fi
  fi
done

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Integration health check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
