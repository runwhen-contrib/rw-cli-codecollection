#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE
# Maps PVC -> PV -> StorageClass -> VAST identifiers. Informational (severity 4).
# Writes JSON array to pvc_trace_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="pvc_trace_issues.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-csi-common.sh
source "${SCRIPT_DIR}/vast-csi-common.sh"

issues_json='[]'
trace_report=""

print_report() {
  { set +x; } 2>/dev/null || true
  echo
  echo "=== VAST PVC trace for namespace '${NAMESPACE}' (context '${CONTEXT}') ==="
  echo "${trace_report:-  No VAST-backed PVCs found.}"
}
trap print_report EXIT

pvcs_json=$(list_vast_pvcs_json "${NAMESPACE}")
pvc_count=$(echo "$pvcs_json" | jq '.items | length')

if [[ "$pvc_count" -eq 0 ]]; then
  # Refine: scan all PVCs and filter by bound PV driver / storage class provisioner
  all_pvcs=$(k8s get pvc -n "${NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
  pvcs_json=$(echo "$all_pvcs" | jq -c '{items: []}')
  while IFS= read -r pvc_line; do
    [[ -z "$pvc_line" ]] && continue
    if is_vast_pvc_json "$pvc_line"; then
      pvcs_json=$(echo "$pvcs_json" | jq -c --argjson item "$pvc_line" '.items += [$item]')
    fi
  done < <(echo "$all_pvcs" | jq -c '.items[]?')
  pvc_count=$(echo "$pvcs_json" | jq '.items | length')
fi

if [[ "$pvc_count" -eq 0 ]]; then
  issues_json=$(append_issue "$issues_json" \
    "No VAST CSI-backed PVCs found in namespace \`${NAMESPACE}\`" \
    "No PersistentVolumeClaims using csi.vastdata.com (or VAST-named StorageClasses) were discovered." \
    4 \
    "Confirm workloads in this namespace use a VAST StorageClass. Adjust generation rules if this namespace should not be monitored.")
  write_issues "$OUTPUT_FILE" "$issues_json"
  exit 0
fi

while IFS= read -r pvc_line; do
  [[ -z "$pvc_line" ]] && continue
  pvc_name=$(echo "$pvc_line" | jq -r '.metadata.name')
  sc_name=$(echo "$pvc_line" | jq -r '.spec.storageClassName // "default"')
  pv_name=$(echo "$pvc_line" | jq -r '.spec.volumeName // empty')
  phase=$(echo "$pvc_line" | jq -r '.status.phase // "Unknown"')

  sc_json=$(k8s get storageclass "$sc_name" -o json 2>/dev/null || echo '{}')
  sc_params=$(echo "$sc_json" | jq -c '.parameters // {}')
  provisioner=$(echo "$sc_json" | jq -r '.provisioner // "unknown"')

  pv_json='{}'
  volume_handle=""
  driver=""
  view_path=""
  tenant=""
  vip=""
  if [[ -n "$pv_name" ]]; then
    pv_json=$(k8s get pv "$pv_name" -o json 2>/dev/null || echo '{}')
    volume_handle=$(echo "$pv_json" | jq -r '.spec.csi.volumeHandle // empty')
    driver=$(echo "$pv_json" | jq -r '.spec.csi.driver // empty')
    view_path=$(echo "$pv_json" | jq -r '.spec.csi.volumeAttributes.view_path // .spec.csi.volumeAttributes.root_export // empty')
    tenant=$(echo "$pv_json" | jq -r '.spec.csi.volumeAttributes.tenant // .spec.csi.volumeAttributes.tenant_name // empty')
    vip=$(echo "$pv_json" | jq -r '.spec.csi.volumeAttributes.vip // .spec.csi.volumeAttributes.endpoint // empty')
  fi

  if [[ -z "$view_path" ]]; then
    view_path=$(echo "$sc_params" | jq -r '.view_policy // .root_export // .view // empty')
  fi
  if [[ -z "$tenant" ]]; then
    tenant=$(echo "$sc_params" | jq -r '.tenant // .tenant_name // empty')
  fi
  if [[ -z "$vip" ]]; then
    vip=$(echo "$sc_params" | jq -r '.endpoint // .vip_pool // .vip // empty')
  fi

  trace_report+=$'\n'"--- PVC: ${pvc_name} (phase=${phase})"
  trace_report+=$'\n'"    StorageClass: ${sc_name} (provisioner=${provisioner})"
  trace_report+=$'\n'"    PV: ${pv_name:-unbound} (driver=${driver:-n/a})"
  trace_report+=$'\n'"    volumeHandle: ${volume_handle:-n/a}"
  trace_report+=$'\n'"    VAST view/path: ${view_path:-unknown}"
  trace_report+=$'\n'"    tenant: ${tenant:-unknown}"
  trace_report+=$'\n'"    VIP/endpoint: ${vip:-unknown}"

  if [[ "$phase" != "Bound" ]]; then
    issues_json=$(append_issue "$issues_json" \
      "VAST PVC \`${pvc_name}\` is not Bound in namespace \`${NAMESPACE}\`" \
      "PVC phase=${phase}. StorageClass=${sc_name}, PV=${pv_name:-none}. Trace: view=${view_path:-?}, tenant=${tenant:-?}, vip=${vip:-?}." \
      3 \
      "Inspect PVC events and controller logs in ${CSI_NAMESPACE:-vast-csi}. Verify VMS view policy and quota for tenant ${tenant:-unknown}.")
  elif [[ -z "$volume_handle" && "$driver" != "csi.vastdata.com" ]]; then
    issues_json=$(append_issue "$issues_json" \
      "VAST PVC \`${pvc_name}\` missing CSI volumeHandle metadata" \
      "Bound PVC ${pvc_name} lacks parseable VAST identifiers in PV ${pv_name}." \
      4 \
      "Describe PV ${pv_name} and confirm the VAST CSI driver populated volumeHandle and volumeAttributes.")
  else
    issues_json=$(append_issue "$issues_json" \
      "VAST storage trace for PVC \`${pvc_name}\` in namespace \`${NAMESPACE}\`" \
      "PVC ${pvc_name} -> PV ${pv_name} -> SC ${sc_name}. view=${view_path:-unknown}, tenant=${tenant:-unknown}, vip=${vip:-unknown}, volumeHandle=${volume_handle:-n/a}." \
      4 \
      "Use this mapping when correlating workload symptoms with VMS tenant/view metrics.")
  fi
done < <(echo "$pvcs_json" | jq -c '.items[]')

write_issues "$OUTPUT_FILE" "$issues_json"
