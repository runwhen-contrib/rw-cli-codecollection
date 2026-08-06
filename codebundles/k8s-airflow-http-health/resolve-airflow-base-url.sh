#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Validates PROXY_BASE_URL or establishes kubectl port-forward, then verifies
# the webserver responds on GET /health (read-only smoke check).
# Writes issues JSON to OUTPUT_FILE (default: resolve_airflow_base_url_issues.json).
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${AIRFLOW_WEBSERVER_SERVICE_NAME:?Must set AIRFLOW_WEBSERVER_SERVICE_NAME}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_airflow_http_portforward_helper.sh"

OUTPUT_FILE="${OUTPUT_FILE:-resolve_airflow_base_url_issues.json}"
issues_json='[]'
MAX_TIME="${CURL_MAX_TIME:-20}"

if ! ensure_airflow_proxy_base_url; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot reach Airflow webserver base URL for \`${AIRFLOW_WEBSERVER_SERVICE_NAME}\`" \
    --arg details "PROXY_BASE_URL was unset and kubectl port-forward to the Service failed or kubectl is unavailable." \
    --argjson severity 3 \
    --arg next_steps "Verify kubeconfig RBAC for port-forward, Service name and namespace, and that the webserver Pod is running." \
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

BASE_URL="${PROXY_BASE_URL%/}"
tmpf=$(mktemp)
code=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
body=$(head -c 400 "$tmpf" || true)
rm -f "$tmpf"

echo "GET ${BASE_URL}/health -> HTTP ${code}"

if [[ "$code" != "200" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Airflow webserver /health not reachable at resolved base URL" \
    --arg details "Expected HTTP 200 from ${BASE_URL}/health after resolving PROXY_BASE_URL. Got HTTP ${code}. Body preview: ${body}" \
    --argjson severity 3 \
    --arg next_steps "Confirm the Airflow web UI is up, Ingress or Service port matches AIRFLOW_HTTP_PORT, and network policy allows the runner to reach the Service." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

if [[ "$code" == "200" ]] && ! jq -e . >/dev/null 2>&1 <<<"$body"; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Airflow /health returned non-JSON response" \
    --arg details "Expected JSON from ${BASE_URL}/health. Preview: ${body}" \
    --argjson severity 2 \
    --arg next_steps "Verify this is the Airflow webserver and not an ingress error page." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Base URL resolution complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
