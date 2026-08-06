#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Probes read-only REST routes: /api/v1/health, /api/v2/monitor/health, /api/v1/version
# Optional AIRFLOW_API_CREDENTIALS JSON for Bearer or basic auth.
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_airflow_http_portforward_helper.sh"
ensure_airflow_proxy_base_url

OUTPUT_FILE="${OUTPUT_FILE:-check_airflow_api_health_issues.json}"
issues_json='[]'
BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-25}"

curl_auth=()
if [[ -n "${AIRFLOW_API_CREDENTIALS:-}" ]] && echo "${AIRFLOW_API_CREDENTIALS}" | jq -e . >/dev/null 2>&1; then
  token=$(echo "${AIRFLOW_API_CREDENTIALS}" | jq -r '.token // .bearer_token // empty')
  user=$(echo "${AIRFLOW_API_CREDENTIALS}" | jq -r '.username // .user // empty')
  password=$(echo "${AIRFLOW_API_CREDENTIALS}" | jq -r '.password // empty')
  if [[ -n "$token" && "$token" != "null" ]]; then
    curl_auth=(-H "Authorization: Bearer ${token}")
  elif [[ -n "$user" && "$user" != "null" && -n "$password" && "$password" != "null" ]]; then
    curl_auth=(-u "${user}:${password}")
  fi
fi

try_paths=(
  "/api/v1/health"
  "/api/v2/monitor/health"
  "/api/v1/version"
)

ok=0
last_code="000"
last_path=""
for path in "${try_paths[@]}"; do
  tmpf=$(mktemp)
  c=$(curl -sS --max-time "$MAX_TIME" "${curl_auth[@]}" -o "$tmpf" -w "%{http_code}" "${BASE_URL}${path}" 2>/dev/null || echo "000")
  body=$(cat "$tmpf" || true)
  rm -f "$tmpf"
  last_code="$c"
  last_path="$path"
  echo "GET ${BASE_URL}${path} -> HTTP ${c}"
  preview=$(echo "$body" | head -c 200 | tr '\n' ' ')
  [[ -n "$preview" ]] && echo "  body: ${preview}"

  if [[ "$c" == "200" ]]; then
    ok=1
    break
  fi
  # Unauthenticated caller: 401/403 indicates the API router is responding
  if [[ "$c" == "401" || "$c" == "403" ]] && [[ ${#curl_auth[@]} -eq 0 ]]; then
    echo "API responded with ${c} (auth required). Configure airflow_api_credentials to probe authenticated routes."
    ok=1
    break
  fi
done

if [[ "$ok" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Airflow REST API probe did not succeed" \
    --arg details "Tried ${try_paths[*]} on ${BASE_URL}. Last: ${last_path} HTTP ${last_code}. Supply AIRFLOW_API_CREDENTIALS JSON if RBAC blocks anonymous access." \
    --argjson severity 2 \
    --arg next_steps "Verify Airflow version and API path, enable REST API, and add token or basic-auth credentials if required." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "API health check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
