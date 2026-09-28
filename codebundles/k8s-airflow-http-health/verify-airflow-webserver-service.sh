#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# kubectl: Service and Endpoints for the Airflow webserver (no HTTP calls).
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${AIRFLOW_WEBSERVER_SERVICE_NAME:?Must set AIRFLOW_WEBSERVER_SERVICE_NAME}"

OUTPUT_FILE="${OUTPUT_FILE:-verify_airflow_webserver_service_issues.json}"
issues_json='[]'
KBIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
PORT="${AIRFLOW_HTTP_PORT:-8080}"

echo "Verifying svc/${AIRFLOW_WEBSERVER_SERVICE_NAME} in ns ${NAMESPACE} (context ${CONTEXT}), expected port ${PORT}."

if ! command -v "$KBIN" &>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Kubernetes CLI not found for Airflow Service verification" \
    --arg details "Expected ${KBIN} on PATH." \
    --argjson severity 3 \
    --arg next_steps "Install kubectl or set KUBERNETES_DISTRIBUTION_BINARY to oc for OpenShift." \
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

if ! svc_json=$("$KBIN" get svc "$AIRFLOW_WEBSERVER_SERVICE_NAME" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Kubernetes Service \`${AIRFLOW_WEBSERVER_SERVICE_NAME}\` not found in namespace \`${NAMESPACE}\`" \
    --arg details "kubectl get svc failed for context ${CONTEXT}." \
    --argjson severity 3 \
    --arg next_steps "Verify AIRFLOW_WEBSERVER_SERVICE_NAME, namespace, and kubeconfig context." \
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

svc_type=$(echo "$svc_json" | jq -r '.spec.type // "<unset>"')
svc_cluster_ip=$(echo "$svc_json" | jq -r '.spec.clusterIP // "<none>"')
svc_ports=$(echo "$svc_json" | jq -c '[.spec.ports[]? | {port, targetPort, protocol, name}]' 2>/dev/null || echo "[]")
svc_selector=$(echo "$svc_json" | jq -c '.spec.selector // {}' 2>/dev/null || echo "{}")
echo "Service: type=${svc_type} clusterIP=${svc_cluster_ip} selector=${svc_selector}"
echo "         ports=${svc_ports}"

ep_addrs=$("$KBIN" get endpoints "$AIRFLOW_WEBSERVER_SERVICE_NAME" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null \
  | jq '[.subsets[]?.addresses[]?] | length' 2>/dev/null || echo 0)
echo "Endpoints: ready_addresses=${ep_addrs}"

if [[ "${ep_addrs:-0}" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No endpoints ready for Service \`${AIRFLOW_WEBSERVER_SERVICE_NAME}\` in \`${NAMESPACE}\`" \
    --arg details "Endpoints show zero addresses; HTTP checks may fail due to missing backing Pods." \
    --argjson severity 3 \
    --arg next_steps "Check Deployment/StatefulSet Pods, selectors, and readiness probes for the Airflow webserver workload." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

port_match=$(echo "$svc_json" | jq --arg p "$PORT" '[.spec.ports[]? | select(.port == ($p|tonumber))] | length' 2>/dev/null || echo 0)
echo "Port check: expected=${PORT} match_count=${port_match}"
if [[ "${port_match:-0}" -eq 0 ]]; then
  ports=$(echo "$svc_json" | jq -c '[.spec.ports[]?.port]' 2>/dev/null || echo "[]")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Service port may not match AIRFLOW_HTTP_PORT for \`${AIRFLOW_WEBSERVER_SERVICE_NAME}\`" \
    --arg details "Expected port ${PORT} on Service. Found ports: ${ports}" \
    --argjson severity 2 \
    --arg next_steps "Align AIRFLOW_HTTP_PORT and PROXY_BASE_URL with spec.ports." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "Kubernetes service verification complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"
