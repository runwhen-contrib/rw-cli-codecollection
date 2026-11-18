#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# Optional HTTP GETs for scheduler/triggerer Services when names are set.
# Uses the first TCP port on each Service. If no route returns HTTP 200,
# logs an informational note (many charts do not expose HTTP on these tiers).
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/_airflow_http_portforward_helper.sh"

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="${OUTPUT_FILE:-check_airflow_scheduler_http_issues.json}"
issues_json='[]'
KBIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
MAX_TIME="${CURL_MAX_TIME:-12}"

check_optional_service() {
  local svc_name="$1"
  local role_label="$2"
  if [[ -z "$svc_name" ]]; then
    echo "${role_label}: service name not set — skipping."
    return 0
  fi

  echo "--- Optional ${role_label}: svc/${svc_name} ---"

  if ! svc_json=$("$KBIN" get svc "$svc_name" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Optional ${role_label} Service \`${svc_name}\` not found" \
      --arg details "Service name was set but kubectl get svc failed." \
      --argjson severity 3 \
      --arg next_steps "Fix the Service name or clear AIRFLOW_SCHEDULER_SERVICE_NAME / AIRFLOW_TRIGGERER_SERVICE_NAME if this tier is not in use." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
    return 0
  fi

  ep_addrs=$("$KBIN" get endpoints "$svc_name" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null \
    | jq '[.subsets[]?.addresses[]?] | length' 2>/dev/null || echo 0)
  echo "Endpoints ready addresses: ${ep_addrs}"
  if [[ "${ep_addrs:-0}" -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Optional ${role_label} Service \`${svc_name}\` has no ready endpoints" \
      --arg details "No backing addresses; HTTP checks against this tier will not work until Pods register." \
      --argjson severity 3 \
      --arg next_steps "Inspect workloads, selectors, and readiness for ${svc_name}." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
    return 0
  fi

  remote_port=$(echo "$svc_json" | jq -r '.spec.ports[0].port // empty')
  if [[ -z "$remote_port" || "$remote_port" == "null" ]]; then
    echo "No Service ports; skipping HTTP probe."
    return 0
  fi

  export AIRFLOW_WEBSERVER_SERVICE_NAME="$svc_name"
  export AIRFLOW_HTTP_PORT="$remote_port"
  unset PROXY_BASE_URL

  if ! ensure_airflow_proxy_base_url; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Cannot port-forward to optional ${role_label} Service \`${svc_name}\`" \
      --arg details "kubectl port-forward failed for ${svc_name}:${remote_port}." \
      --argjson severity 4 \
      --arg next_steps "Verify RBAC for port-forward to this Service." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
    _airflow_cleanup_portforward 2>/dev/null || true
    return 0
  fi

  BASE_URL="${PROXY_BASE_URL%/}"
  local found=0
  for path in "/health" "/metrics" "/"; do
    code=$(curl -sS --max-time "$MAX_TIME" -o /dev/null -w "%{http_code}" "${BASE_URL}${path}" 2>/dev/null || echo "000")
    echo "GET ${BASE_URL}${path} -> HTTP ${code}"
    if [[ "$code" == "200" ]]; then
      found=1
      break
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    echo "NOTE: No HTTP 200 from /health, /metrics, or / on port ${remote_port}. Many Helm charts do not expose an HTTP listener here; this is informational."
  fi

  _airflow_cleanup_portforward 2>/dev/null || true
}

check_optional_service "${AIRFLOW_SCHEDULER_SERVICE_NAME:-}" "scheduler"
check_optional_service "${AIRFLOW_TRIGGERER_SERVICE_NAME:-}" "triggerer"

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Optional scheduler/triggerer HTTP check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
