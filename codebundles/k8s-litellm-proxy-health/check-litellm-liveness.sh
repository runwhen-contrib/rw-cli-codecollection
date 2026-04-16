#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Calls GET /health/liveliness (LiteLLM spelling) with optional /health/live fallback.
# Writes JSON issues array to OUTPUT_FILE.
# -----------------------------------------------------------------------------
: "${PROXY_BASE_URL:?Must set PROXY_BASE_URL}"

OUTPUT_FILE="${OUTPUT_FILE:-litellm_liveness_issues.json}"
issues_json='[]'
BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-25}"

http_code=""
for path in "/health/liveliness" "/health/live"; do
  tmpf=$(mktemp)
  c=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" "${BASE_URL}${path}" 2>/dev/null || echo "000")
  body=$(cat "$tmpf" || true)
  rm -f "$tmpf"
  http_code="$c"
  if [[ "$http_code" == "200" ]]; then
    break
  fi
done

if [[ "$http_code" != "200" ]]; then
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
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Liveness check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
