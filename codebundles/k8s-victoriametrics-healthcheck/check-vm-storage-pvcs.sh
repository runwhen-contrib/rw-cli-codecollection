#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists PVCs used by VictoriaMetrics storage workloads; flags bad phases and events.
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="${OUTPUT_FILE:-vm_storage_pvc_issues.json}"
issues_json='[]'

LABEL_ARGS=()
if [[ -n "${VM_LABEL_SELECTOR:-}" ]]; then
  LABEL_ARGS=(-l "${VM_LABEL_SELECTOR}")
fi

append_issue() {
  local title="$1"
  local details="$2"
  local severity="$3"
  local next_steps="$4"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
}

if ! pvc_json=$("$KUBECTL" get pvc -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null); then
  append_issue "Cannot list PVCs in \`${NAMESPACE}\`" "kubectl get pvc failed." 4 "Verify RBAC and namespace."
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  exit 0
fi

# Resolve StatefulSet volume claim names tied to VM workloads
sts_json=$("$KUBECTL" get statefulset -n "$NAMESPACE" --context "$CONTEXT" "${LABEL_ARGS[@]}" -o json 2>/dev/null || echo '{"items":[]}')
vm_claims=$(echo "$sts_json" | jq -r '
  [.items[] |
    select(
      ((.metadata.labels["app.kubernetes.io/name"] // "") | test("victoria-metrics|vmstorage|vmselect|vminsert|vmagent"; "i"))
      or ((.metadata.name // "") | test("vmstorage|vmselect|vminsert"; "i"))
    ) |
    .spec.volumeClaimTemplates[]?.metadata.name // empty
  ] | unique | .[]' 2>/dev/null || true)

mapfile -t pvc_items < <(echo "$pvc_json" | jq -c '.items[]')
for pvc in "${pvc_items[@]:-}"; do
  [[ -z "${pvc:-}" ]] && continue
  pname=$(echo "$pvc" | jq -r '.metadata.name')
  phase=$(echo "$pvc" | jq -r '.status.phase // "Unknown"')
  # Match VM-related PVCs by name/label or STS template
  match=false
  if echo "$pvc" | jq -e '.metadata.labels["app.kubernetes.io/name"]? | test("victoria-metrics|vmstorage|vmselect|vminsert|vmagent"; "i")' >/dev/null 2>&1; then
    match=true
  fi
  if [[ "$pname" =~ (vmstorage|vm-select|vm-insert|victoria-metrics|vm-) ]]; then
    match=true
  fi
  if echo "$vm_claims" | grep -qE "^${pname}$|^-?${pname}-[0-9]+$" 2>/dev/null; then
    match=true
  fi
  [[ "$match" == "false" ]] && continue

  if [[ "$phase" != "Bound" ]]; then
    cap=$(echo "$pvc" | jq -r '.status.capacity.storage // "unknown"')
    append_issue "PVC \`${pname}\` phase ${phase} in \`${NAMESPACE}\`" "Capacity (if bound): ${cap}. Phase indicates binding or provisioning problem." 3 "kubectl describe pvc ${pname} -n ${NAMESPACE} --context ${CONTEXT}; check StorageClass and provisioner events."
  fi

  # Volume binding failures from conditions
  while IFS= read -r cond; do
    [[ -z "$cond" ]] && continue
    ctype=$(echo "$cond" | jq -r '.type')
    cstat=$(echo "$cond" | jq -r '.status')
    cmsg=$(echo "$cond" | jq -r '.message // ""')
    if [[ "$cstat" == "False" ]] && [[ "$ctype" =~ (Resizing|FileSystemResize|VolumeBinding) ]]; then
      append_issue "PVC \`${pname}\` condition ${ctype} is False" "${cmsg}" 3 "Review storage class, quota, and events for ${pname}."
    fi
  done < <(echo "$pvc" | jq -c '.status.conditions[]? // empty')
done

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "PVC analysis completed. Results saved to $OUTPUT_FILE"
