#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Calls GET /health/liveliness (LiteLLM spelling) with optional /health/live fallback.
# Writes JSON issues array to OUTPUT_FILE.
#
# PROXY_BASE_URL is optional. When unset, kubectl port-forward is used against
# svc/${LITELLM_SERVICE_NAME} on ${LITELLM_HTTP_PORT}.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_portforward_helper.sh"
ensure_proxy_base_url

OUTPUT_FILE="${OUTPUT_FILE:-litellm_liveness_issues.json}"
issues_json='[]'
BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-25}"

http_code=""
last_path=""
last_body=""
for path in "/health/liveliness" "/health/live"; do
  last_path="$path"
  tmpf=$(mktemp)
  c=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" "${BASE_URL}${path}" 2>/dev/null || echo "000")
  body=$(cat "$tmpf" || true)
  rm -f "$tmpf"
  http_code="$c"
  body_preview=$(printf '%s' "$body" | head -c 300 | tr -d '\r' | tr '\n' ' ')
  echo "GET ${BASE_URL}${path} -> HTTP ${http_code}"
  if [[ -n "$body_preview" ]]; then
    echo "  body: ${body_preview}"
  fi
  last_body="$body"
  if [[ "$http_code" == "200" ]]; then
    break
  fi
done

if [[ "$http_code" != "200" ]]; then
  body="$last_body"
  echo "Result: liveness probe FAILED (last path ${last_path}, HTTP ${http_code})."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "LiteLLM liveness HTTP failure for \`${BASE_URL}\`" \
    --arg details "Expected HTTP 200 from /health/liveliness (or /health/live). Got HTTP ${http_code:-unknown}." \
    --argjson severity 4 \
    --arg next_steps "Verify the proxy is running, PROXY_BASE_URL is correct, and network path from the runner allows reaching the API (ClusterIP, port-forward, or ingress)." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
else
  echo "Result: liveness OK (HTTP 200 from ${last_path})."
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Liveness check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
