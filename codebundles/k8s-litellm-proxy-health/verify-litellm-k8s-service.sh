#!/usr/bin/env bash
set -euo pipefail
# -----------------------------------------------------------------------------
# kubectl: Service and Endpoints presence for correlation with API failures.
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${LITELLM_SERVICE_NAME:?Must set LITELLM_SERVICE_NAME}"
# PROXY_BASE_URL is intentionally optional here; this script only inspects the
# Kubernetes Service/Endpoints and does not make HTTP calls to the proxy.

OUTPUT_FILE="${OUTPUT_FILE:-litellm_k8s_service_issues.json}"
issues_json='[]'
KBIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
PORT="${LITELLM_HTTP_PORT:-4000}"

echo "Verifying svc/${LITELLM_SERVICE_NAME} in ns ${NAMESPACE} (context ${CONTEXT}), expected port ${PORT}."

if ! command -v "$KBIN" &>/dev/null; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Kubernetes CLI not found for LiteLLM service verification" \
    --arg details "Expected ${KBIN} on PATH." \
    --argjson severity 3 \
    --arg next_steps "Install kubectl or set KUBERNETES_DISTRIBUTION_BINARY to oc if using OpenShift." \
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

if ! svc_json=$("$KBIN" get svc "$LITELLM_SERVICE_NAME" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Kubernetes Service \`${LITELLM_SERVICE_NAME}\` not found in namespace \`${NAMESPACE}\`" \
    --arg details "kubectl get svc failed for context ${CONTEXT}." \
    --argjson severity 3 \
    --arg next_steps "Verify the service name, namespace, and kubeconfig context." \
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

ep_addrs=$("$KBIN" get endpoints "$LITELLM_SERVICE_NAME" -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null \
  | jq '[.subsets[]?.addresses[]?] | length' 2>/dev/null || echo 0)
echo "Endpoints: ready_addresses=${ep_addrs}"

if [[ "${ep_addrs:-0}" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No endpoints ready for Service \`${LITELLM_SERVICE_NAME}\` in \`${NAMESPACE}\`" \
    --arg details "Endpoints show zero addresses. API failures may be due to missing backing Pods." \
    --argjson severity 3 \
    --arg next_steps "Check Deployment/StatefulSet pods, selectors, and readiness probes for the LiteLLM workload." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

port_match=$(echo "$svc_json" | jq --argjson p "$PORT" '[.spec.ports[]? | select(.port == $p)] | length' 2>/dev/null || echo 0)
echo "Port check: expected=${PORT} match_count=${port_match}"
if [[ "${port_match:-0}" -eq 0 ]]; then
  ports=$(echo "$svc_json" | jq -c '[.spec.ports[]?.port]' 2>/dev/null || echo "[]")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Service port may not match LITELLM_HTTP_PORT for \`${LITELLM_SERVICE_NAME}\`" \
    --arg details "Expected port ${PORT} on Service. Found ports: ${ports}" \
    --argjson severity 2 \
    --arg next_steps "Align LITELLM_HTTP_PORT and PROXY_BASE_URL with the Service spec.ports." \
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
