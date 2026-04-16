#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Reviews Validating/MutatingWebhookConfiguration objects related to Karpenter.
# Writes JSON array to webhook_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${KARPENTER_NAMESPACE:?Must set KARPENTER_NAMESPACE}"

OUTPUT_FILE="webhook_issues.json"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
issues_json='[]'

vwh=$("${KUBECTL}" get validatingwebhookconfiguration -o json --context "${CONTEXT}" 2>/dev/null || echo '{"items":[]}')
mwh=$("${KUBECTL}" get mutatingwebhookconfiguration -o json --context "${CONTEXT}" 2>/dev/null || echo '{"items":[]}')

append_issue() {
  local title="$1" details="$2" severity="$3" next_steps="$4"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
}

while IFS= read -r item; do
  [[ -z "$item" ]] && continue
  name=$(echo "$item" | jq -r '.metadata.name')
  wh_count=$(echo "$item" | jq '.webhooks | length')
  if [[ "$wh_count" -eq 0 ]]; then
    append_issue "ValidatingWebhookConfiguration \`${name}\` has no webhooks" \
      "Resource exists but defines zero webhooks." 3 \
      "Reinstall or repair the Karpenter Helm chart webhook manifests."
    continue
  fi
  idx=0
  while IFS= read -r w; do
    svc_name=$(echo "$w" | jq -r '.clientConfig.service.name // empty')
    svc_ns=$(echo "$w" | jq -r '.clientConfig.service.namespace // empty')
    cab=$(echo "$w" | jq -r '.clientConfig.caBundle // empty')
    cab_len=${#cab}
    has_url=$(echo "$w" | jq -r 'if .clientConfig.url then "yes" else "no" end')
    fp=$(echo "$w" | jq -r '.failurePolicy // "Fail"')
    if [[ "$has_url" == "yes" ]]; then
      if [[ "$cab_len" -eq 0 ]]; then
        append_issue "Webhook in \`${name}\` uses client URL without caBundle" \
          "failurePolicy=${fp}; external URL webhooks should include a CA bundle for verification." 3 \
          "Confirm chart version; rotate webhook TLS secret and re-apply validating webhook configuration."
      fi
    elif [[ -n "$svc_ns" ]] && [[ "$svc_ns" == "${KARPENTER_NAMESPACE}" ]]; then
      if [[ "$cab_len" -eq 0 ]]; then
        append_issue "Karpenter webhook in \`${name}\` has empty caBundle for service \`${svc_name}\`" \
          "APIServer may reject TLS to the Karpenter service (${svc_ns}/${svc_name}). Some installs rely on service CA — verify your cluster version and chart." 2 \
          "Compare with a working cluster: kubectl get validatingwebhookconfiguration ${name} -o yaml --context ${CONTEXT}"
      fi
      if ! "${KUBECTL}" get svc "${svc_name}" -n "${svc_ns}" --context "${CONTEXT}" &>/dev/null; then
        append_issue "Webhook service \`${svc_name}\` missing in namespace \`${svc_ns}\`" \
          "ValidatingWebhookConfiguration ${name} references a Service that does not exist." 3 \
          "Check Helm release status and Karpenter service name overrides."
      fi
    fi
    idx=$((idx + 1))
  done < <(echo "$item" | jq -c '.webhooks[]')
done < <(echo "$vwh" | jq -c --arg ns "$KARPENTER_NAMESPACE" '.items[] | select(
  (.metadata.name | test("karpenter"; "i")) or
  (any(.webhooks[]?; (.clientConfig.service.namespace? // "") == $ns))
)')

while IFS= read -r item; do
  [[ -z "$item" ]] && continue
  name=$(echo "$item" | jq -r '.metadata.name')
  wh_count=$(echo "$item" | jq '.webhooks | length')
  if [[ "$wh_count" -eq 0 ]]; then
    append_issue "MutatingWebhookConfiguration \`${name}\` has no webhooks" \
      "Resource exists but defines zero webhooks." 3 \
      "Repair Karpenter mutating webhook manifests from the chart."
    continue
  fi
  while IFS= read -r w; do
    svc_name=$(echo "$w" | jq -r '.clientConfig.service.name // empty')
    svc_ns=$(echo "$w" | jq -r '.clientConfig.service.namespace // empty')
    cab=$(echo "$w" | jq -r '.clientConfig.caBundle // empty')
    cab_len=${#cab}
    has_url=$(echo "$w" | jq -r 'if .clientConfig.url then "yes" else "no" end')
    fp=$(echo "$w" | jq -r '.failurePolicy // "Fail"')
    if [[ "$has_url" == "yes" ]] && [[ "$cab_len" -eq 0 ]]; then
      append_issue "Mutating webhook in \`${name}\` uses URL without caBundle" \
        "failurePolicy=${fp}" 3 \
        "Verify TLS material for the mutating webhook endpoint."
    elif [[ -n "$svc_ns" ]] && [[ "$svc_ns" == "${KARPENTER_NAMESPACE}" ]] && [[ "$cab_len" -eq 0 ]]; then
      append_issue "Karpenter mutating webhook in \`${name}\` has empty caBundle" \
        "Service ${svc_ns}/${svc_name}" 2 \
        "kubectl get mutatingwebhookconfiguration ${name} -o yaml --context ${CONTEXT}"
    fi
  done < <(echo "$item" | jq -c '.webhooks[]')
done < <(echo "$mwh" | jq -c --arg ns "$KARPENTER_NAMESPACE" '.items[] | select(
  (.metadata.name | test("karpenter"; "i")) or
  (any(.webhooks[]?; (.clientConfig.service.namespace? // "") == $ns))
)')

# Recent events mentioning webhook failures (cluster-scoped search in namespace)
if ev=$("${KUBECTL}" get events -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" \
  --field-selector type=Warning -o json 2>/dev/null); then
  while IFS= read -r msg; do
    [[ -z "$msg" ]] && continue
    if echo "$msg" | grep -qiE 'webhook|failed calling webhook'; then
      append_issue "Recent Warning event suggests webhook call failures in \`${KARPENTER_NAMESPACE}\`" \
        "$msg" 3 \
        "Check apiserver logs and Karpenter service endpoints; ensure caBundle matches serving cert."
    fi
  done < <(echo "$ev" | jq -r '.items[] | select(.message != null) | .message' | head -n 20)
fi

echo "$issues_json" | jq 'unique_by(.title)' >"$OUTPUT_FILE.tmp" && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
