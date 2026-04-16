#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# GET /health/readiness — surfaces DB/cache connectivity and proxy version.
# -----------------------------------------------------------------------------
: "${PROXY_BASE_URL:?Must set PROXY_BASE_URL}"

OUTPUT_FILE="${OUTPUT_FILE:-litellm_readiness_issues.json}"
issues_json='[]'
BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-25}"

tmpf=$(mktemp)
http_code=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" "${BASE_URL}/health/readiness" 2>/dev/null || echo "000")
body=$(cat "$tmpf" || true)
rm -f "$tmpf"

if [[ "$http_code" != "200" ]]; then
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
