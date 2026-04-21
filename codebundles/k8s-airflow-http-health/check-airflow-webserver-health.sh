#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# GET /health and evaluate Airflow 2.x-style JSON (metadatabase, scheduler, ...).
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_airflow_http_portforward_helper.sh"
ensure_airflow_proxy_base_url

OUTPUT_FILE="${OUTPUT_FILE:-check_airflow_webserver_health_issues.json}"
issues_json='[]'
BASE_URL="${PROXY_BASE_URL%/}"
MAX_TIME="${CURL_MAX_TIME:-25}"

tmpf=$(mktemp)
code=$(curl -sS --max-time "$MAX_TIME" -o "$tmpf" -w "%{http_code}" "${BASE_URL}/health" 2>/dev/null || echo "000")
raw=$(cat "$tmpf" || true)
rm -f "$tmpf"

echo "GET ${BASE_URL}/health -> HTTP ${code}"

if [[ "$code" != "200" ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Airflow webserver /health HTTP failure" \
    --arg details "Expected HTTP 200 from ${BASE_URL}/health. Got HTTP ${code}." \
    --argjson severity 3 \
    --arg next_steps "Check webserver Pods, readiness probes, and whether PROXY_BASE_URL or port-forward targets the correct Service port." \
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

if ! echo "$raw" | jq -e . >/dev/null 2>&1; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Airflow /health body is not valid JSON" \
    --arg details "Response preview: $(echo "$raw" | head -c 500 | tr '\n' ' ')" \
    --argjson severity 3 \
    --arg next_steps "Confirm you are hitting the Airflow webserver and not a proxy error page." \
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

# Critical subsystems: metadatabase must be healthy when present; scheduler when status is non-null
_check_component() {
  local key="$1"
  local label="$2"
  local status
  status=$(echo "$raw" | jq -r --arg k "$key" '.[$k].status // empty')
  if [[ -z "$status" || "$status" == "null" ]]; then
    echo "Component ${label}: not reported (optional or not deployed)"
    return 0
  fi
  if [[ "$status" != "healthy" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Airflow ${label} reports unhealthy in /health JSON" \
      --arg details "${label} status=${status} (from ${BASE_URL}/health)" \
      --argjson severity 3 \
      --arg next_steps "Inspect ${label} Pods/logs and related dependencies (for example metadata DB for metadatabase, scheduler Pods for scheduler)." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
  else
    echo "Component ${label}: healthy"
  fi
}

_check_component "metadatabase" "metadatabase"
_check_component "scheduler" "scheduler"
_check_component "triggerer" "triggerer"
_check_component "dag_processor" "DAG processor"

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Webserver health check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
