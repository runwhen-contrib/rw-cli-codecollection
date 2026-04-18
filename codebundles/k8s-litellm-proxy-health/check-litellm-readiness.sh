#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# GET /health/readiness — surfaces DB/cache connectivity and proxy version.
#
# PROXY_BASE_URL is optional. When unset, kubectl port-forward is used against
# svc/${LITELLM_SERVICE_NAME} on ${LITELLM_HTTP_PORT}.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
ensure_proxy_base_url

OUTPUT_FILE="${OUTPUT_FILE:-litellm_readiness_issues.json}"
issues_json='[]'
BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-25}"

tmpf=$(mktemp)
http_code=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" "${BASE_URL}/health/readiness" 2>/dev/null || echo "000")
body=$(cat "$tmpf" || true)
rm -f "$tmpf"
body_preview=$(printf '%s' "$body" | head -c 500 | tr -d '\r' | tr '\n' ' ')
echo "GET ${BASE_URL}/health/readiness -> HTTP ${http_code}"
if [[ -n "$body_preview" ]]; then
  echo "  body: ${body_preview}"
fi

if [[ "$http_code" != "200" ]]; then
  echo "Result: readiness probe FAILED (HTTP ${http_code})."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM readiness endpoint unreachable for \`${BASE_URL}\`" \
    --arg details "GET /health/readiness returned HTTP ${http_code}. Response (truncated): $(echo "$body" | head -c 600)" \
    --argjson severity 3 \
    --arg next_steps "Confirm the proxy process is listening on PROXY_BASE_URL and that readiness probes match this path." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" | jq . >"$OUTPUT_FILE"
  echo "Readiness check complete. Issues written to $OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

if ! echo "$body" | jq -e . >/dev/null 2>&1; then
  echo "Result: readiness returned non-JSON response."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM readiness returned non-JSON for \`${BASE_URL}\`" \
    --arg details "Expected JSON from /health/readiness. Raw (truncated): $(echo "$body" | head -c 600)" \
    --argjson severity 3 \
    --arg next_steps "Upgrade or fix the LiteLLM proxy; verify you are hitting the LiteLLM proxy port." \
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

db_status=$(echo "$body" | jq -r '.db // empty')
cache_status=$(echo "$body" | jq -r '.cache // empty')
version=$(echo "$body" | jq -r '.litellm_version // .version // empty')
echo "Parsed: db=${db_status:-<none>} cache=${cache_status:-<none>} version=${version:-<none>}"

if [[ "$db_status" == "Not connected" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM database not connected for \`${BASE_URL}\`" \
    --arg details "$(echo "$body" | jq -c .)" \
    --argjson severity 3 \
    --arg next_steps "Fix database credentials, network policy, or proxy configuration so the proxy can reach its configured database." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

if [[ -n "$cache_status" && "$cache_status" != "null" ]]; then
  if echo "$cache_status" | grep -qi 'fail\|error\|down\|disconnect'; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "LiteLLM cache reported unhealthy for \`${BASE_URL}\`" \
      --arg details "cache field: ${cache_status}. Full payload: $(echo "$body" | jq -c .)" \
      --argjson severity 2 \
      --arg next_steps "Verify Redis or other cache connectivity and proxy cache settings." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
  fi
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Readiness check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
