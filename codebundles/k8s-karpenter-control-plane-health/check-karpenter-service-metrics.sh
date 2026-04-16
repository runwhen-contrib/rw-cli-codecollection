#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Validates Services/endpoints for metrics and monitoring ports in Karpenter ns.
# Writes JSON array to service_metrics_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${KARPENTER_NAMESPACE:?Must set KARPENTER_NAMESPACE}"

OUTPUT_FILE="service_metrics_issues.json"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
issues_json='[]'

if ! "${KUBECTL}" get ns "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o name &>/dev/null; then
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Namespace \`${KARPENTER_NAMESPACE}\` not found for service checks" \
    --arg details "Cannot assess Service or Endpoints without the namespace." \
    --argjson severity 3 \
    --arg next_steps "Set KARPENTER_NAMESPACE to the controller namespace." \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

svcs=$("${KUBECTL}" get svc -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null || echo '{"items":[]}')

metrics_like=$(echo "$svcs" | jq '[.items[] | select(
    (.metadata.name | test("karpenter"; "i")) or
    (.spec.selector["app.kubernetes.io/name"]? == "karpenter")
  ) | {
    name: .metadata.name,
    ports: [.spec.ports[]? | {name: (.name // ""), port: .port, targetPort: .targetPort}]
  }]')

mcount=$(echo "$metrics_like" | jq 'length')
if [[ "$mcount" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Karpenter-associated Service found in \`${KARPENTER_NAMESPACE}\`" \
    --arg details "Expected a Service selecting the controller (e.g. karpenter) for metrics scraping." \
    --argjson severity 3 \
    --arg next_steps "kubectl get svc -n ${KARPENTER_NAMESPACE} -o wide --context ${CONTEXT}" \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

while IFS= read -r sname; do
  [[ -z "$sname" ]] && continue
  ep=$("${KUBECTL}" get endpoints "$sname" -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null || echo '{}')
  addr_count=$(echo "$ep" | jq '[.subsets[]? | .addresses[]?] | length')
  if [[ "${addr_count:-0}" -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Service \`${sname}\` has no endpoint addresses" \
      --arg details "Metrics and probes may be unreachable; selector may not match running pods." \
      --argjson severity 3 \
      --arg next_steps "kubectl get endpoints ${sname} -n ${KARPENTER_NAMESPACE} -o yaml --context ${CONTEXT}" \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi

  ports=$(echo "$svcs" | jq --arg s "$sname" '.items[] | select(.metadata.name == $s) | .spec.ports')
  has_metrics_name=$(echo "$ports" | jq -r '[.[]? | .name // ""] | map(test("metrics|http-metric|prometheus"; "i")) | any')
  has_common_port=$(echo "$ports" | jq -r '[.[]? | .port] | map(. == 8080 or . == 8443 or . == 10250) | any')
  if [[ "$has_metrics_name" != "true" ]] && [[ "$has_common_port" != "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Service \`${sname}\` may not expose a metrics port" \
      --arg details "No port named metrics/http-metric and no common metrics port (8080/8443) detected." \
      --argjson severity 4 \
      --arg next_steps "Confirm ServiceMonitor/Prometheus scrape settings against actual container ports." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi
done < <(echo "$metrics_like" | jq -r '.[].name')

echo "$issues_json" | jq 'unique_by(.title)' >"$OUTPUT_FILE.tmp" && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
