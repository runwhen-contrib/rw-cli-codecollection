#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT
# Validates VAST StorageClass parameters for common misconfigurations.
# Writes JSON array to storageclass_config_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"

OUTPUT_FILE="storageclass_config_issues.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-csi-common.sh
source "${SCRIPT_DIR}/vast-csi-common.sh"

issues_json='[]'

print_report() {
  { set +x; } 2>/dev/null || true
  echo
  echo "=== VAST StorageClasses in context '${CONTEXT}' ==="
  k8s get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner 2>/dev/null \
    | awk 'NR==1 || /vast|csi\.vastdata/' || true
}
trap print_report EXIT

scs=$(k8s get storageclass -o json 2>/dev/null || echo '{"items":[]}')
vast_scs=$(echo "$scs" | jq -c '[.items[] | select(
  (.provisioner == "csi.vastdata.com") or
  (.provisioner == "kubernetes.io/csi/csi.vastdata.com") or
  (.metadata.name | test("vast"; "i"))
)]')

count=$(echo "$vast_scs" | jq 'length')
if [[ "$count" -eq 0 ]]; then
  issues_json=$(append_issue "$issues_json" \
    "No VAST CSI StorageClasses found in context \`${CONTEXT}\`" \
    "No StorageClass uses provisioner csi.vastdata.com." \
    3 \
    "Install or register a VAST StorageClass via the CSI Helm chart. Confirm provisioner ID csi.vastdata.com.")
  write_issues "$OUTPUT_FILE" "$issues_json"
  exit 0
fi

while IFS= read -r sc; do
  [[ -z "$sc" ]] && continue
  name=$(echo "$sc" | jq -r '.metadata.name')
  params=$(echo "$sc" | jq -r '.parameters // {}')
  mount_opts=$(echo "$sc" | jq -r '.mountOptions // [] | join(",")')
  reclaim=$(echo "$sc" | jq -r '.reclaimPolicy // "Delete"')
  vol_expansion=$(echo "$sc" | jq -r '.allowVolumeExpansion // false')

  endpoint=$(echo "$params" | jq -r '.endpoint // .vip_pool // .vip // empty')
  view_policy=$(echo "$params" | jq -r '.view_policy // .view // .root_export // empty')
  tenant=$(echo "$params" | jq -r '.tenant // .tenant_name // empty')
  qos=$(echo "$params" | jq -r '.qos_policy // .qos // empty')

  echo "StorageClass ${name}: endpoint=${endpoint:-missing}, view=${view_policy:-missing}, tenant=${tenant:-missing}, qos=${qos:-n/a}, mountOptions=${mount_opts:-none}"

  if [[ -z "$endpoint" ]]; then
    issues_json=$(append_issue "$issues_json" \
      "VAST StorageClass \`${name}\` missing endpoint/VIP parameter" \
      "parameters.endpoint (or vip_pool/vip) is not set; dynamic provisioning may fail or use incorrect VIPs." \
      3 \
      "Set endpoint to a reachable VAST VIP or DNS name in the StorageClass parameters.")
  fi

  if [[ -z "$view_policy" ]]; then
    issues_json=$(append_issue "$issues_json" \
      "VAST StorageClass \`${name}\` missing view policy parameter" \
      "No view_policy/view/root_export parameter found; view creation defaults may not match tenant layout." \
      4 \
      "Align view_policy with VMS view templates for the target tenant ${tenant:-unknown}.")
  fi

  if [[ -z "$tenant" ]]; then
    issues_json=$(append_issue "$issues_json" \
      "VAST StorageClass \`${name}\` has no explicit tenant parameter" \
      "Tenant is not specified; volumes may land in an unexpected tenant context." \
      4 \
      "Set tenant or tenant_name to the intended VMS tenant for capacity and QoS tracking.")
  fi

  if [[ "$reclaim" == "Retain" && "$vol_expansion" != "true" ]]; then
    issues_json=$(append_issue "$issues_json" \
      "VAST StorageClass \`${name}\` retains PVs without volume expansion enabled" \
      "reclaimPolicy=Retain with allowVolumeExpansion=false can block operational growth for stateful workloads." \
      4 \
      "Enable allowVolumeExpansion or document manual expansion procedures for Retain volumes.")
  fi

  if echo "$mount_opts" | grep -qi 'sync' && ! echo "$mount_opts" | grep -qi 'noatime'; then
    issues_json=$(append_issue "$issues_json" \
      "VAST StorageClass \`${name}\` uses strict sync mount options" \
      "mountOptions=${mount_opts} may increase latency-sensitive workload impact on NFS." \
      4 \
      "Review mountOptions (mountUmountTimeout, resolveMountSymlinks) against workload latency requirements.")
  fi
done < <(echo "$vast_scs" | jq -c '.[]')

write_issues "$OUTPUT_FILE" "$issues_json"
