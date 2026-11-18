#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE
# OPTIONAL: VAST_VMS_ENDPOINT, VAST_CLUSTER_NAME, vast_vms_credentials secret
# Cross-references failing PVCs with VMS tenant metrics when configured.
# Writes JSON array to vast_correlation_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="vast_correlation_issues.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-csi-common.sh
source "${SCRIPT_DIR}/vast-csi-common.sh"

issues_json='[]'
info_report=""

print_report() {
  { set +x; } 2>/dev/null || true
  echo
  echo "=== Kubernetes/VMS correlation for namespace '${NAMESPACE}' ==="
  echo "${info_report:-  (no correlation output)}"
}
trap print_report EXIT

if [[ -z "${VAST_VMS_ENDPOINT:-}" ]]; then
  info_report="VAST_VMS_ENDPOINT is not configured; skipping backend correlation (informational only)."
  issues_json=$(append_issue "$issues_json" \
    "VMS backend correlation skipped for namespace \`${NAMESPACE}\`" \
    "Set VAST_VMS_ENDPOINT and optional vast_vms_credentials to cross-reference tenant capacity/QoS with Kubernetes storage events." \
    4 \
    "Configure VAST_VMS_ENDPOINT to the VMS REST base URL (e.g. https://vms.example.com) and provide API credentials.")
  write_issues "$OUTPUT_FILE" "$issues_json"
  exit 0
fi

# Parse optional credentials from env (injected by platform from secret)
VMS_USER="${VMS_USERNAME:-${USERNAME:-}}"
VMS_PASS="${VMS_PASSWORD:-${PASSWORD:-}}"
VMS_TOKEN="${VMS_API_TOKEN:-${API_TOKEN:-}}"
if [[ -n "${vast_vms_credentials:-}" ]]; then
  VMS_USER="${VMS_USER:-$(echo "$vast_vms_credentials" | jq -r '.USERNAME // .username // empty')}"
  VMS_PASS="${VMS_PASS:-$(echo "$vast_vms_credentials" | jq -r '.PASSWORD // .password // empty')}"
  VMS_TOKEN="${VMS_TOKEN:-$(echo "$vast_vms_credentials" | jq -r '.API_TOKEN // .api_token // empty')}"
fi

fetch_vms_metrics() {
  local path="$1"
  local url="${VAST_VMS_ENDPOINT%/}${path}"
  if [[ -n "$VMS_TOKEN" ]]; then
    curl -sf -H "Authorization: Bearer ${VMS_TOKEN}" "$url" 2>/dev/null || true
  elif [[ -n "$VMS_USER" && -n "$VMS_PASS" ]]; then
    curl -sf -u "${VMS_USER}:${VMS_PASS}" "$url" 2>/dev/null || true
  else
    curl -sf "$url" 2>/dev/null || true
  fi
}

metrics=$(fetch_vms_metrics "/api/prometheusmetrics/tenants")
if [[ -z "$metrics" ]]; then
  issues_json=$(append_issue "$issues_json" \
    "Unable to fetch VMS tenant metrics from \`${VAST_VMS_ENDPOINT}\`" \
    "Prometheus-format tenant metrics were not returned; verify credentials and network access." \
    3 \
    "Confirm vast_vms_credentials (USERNAME/PASSWORD or API_TOKEN) and VMS API reachability from the execution environment.")
  write_issues "$OUTPUT_FILE" "$issues_json"
  exit 0
fi

info_report+="VMS tenant metrics sample (first 20 lines):"$'\n'
info_report+=$(echo "$metrics" | head -n 20)

# Collect failing / pressured PVCs in namespace
failing_pvcs=$(k8s get pvc -n "${NAMESPACE}" -o json 2>/dev/null | jq -c '
  [.items[] | select(.status.phase != "Bound" or (.metadata.annotations["volume.kubernetes.io/storage-provisioner"]? // "" | test("vast"; "i")))]
')

while IFS= read -r pvc_line; do
  [[ -z "$pvc_line" ]] && continue
  is_vast_pvc_json "$pvc_line" || continue
  pvc_name=$(echo "$pvc_line" | jq -r '.metadata.name')
  phase=$(echo "$pvc_line" | jq -r '.status.phase')
  sc=$(echo "$pvc_line" | jq -r '.spec.storageClassName // empty')
  sc_json=$(k8s get storageclass "$sc" -o json 2>/dev/null || echo '{}')
  tenant=$(echo "$sc_json" | jq -r '.parameters.tenant // .parameters.tenant_name // empty')

  [[ -z "$tenant" ]] && tenant="unknown"
  tenant_pattern=$(echo "$tenant" | sed 's/[][\/.^$*+?{}|()-]/\\&/g')

  cap_line=$(echo "$metrics" | grep -i "tenant.*${tenant_pattern}.*capacity" | head -n 1 || true)
  qos_line=$(echo "$metrics" | grep -i "tenant.*${tenant_pattern}.*qos" | head -n 1 || true)

  if [[ "$phase" != "Bound" ]]; then
    details="PVC ${pvc_name} phase=${phase}, tenant=${tenant}."
    [[ -n "$cap_line" ]] && details+=" VMS capacity hint: ${cap_line}"
    [[ -n "$qos_line" ]] && details+=" VMS QoS hint: ${qos_line}"
    cluster_label="${VAST_CLUSTER_NAME:-${CONTEXT}}"
    issues_json=$(append_issue "$issues_json" \
      "Kubernetes PVC \`${pvc_name}\` failures may correlate with VMS tenant \`${tenant}\` on cluster \`${cluster_label}\`" \
      "$details" \
      3 \
      "Compare CSI driver logs with VMS tenant capacity/QoS dashboards. Expand tenant quota or resolve QoS throttling if backend pressure is confirmed.")
  fi
done < <(echo "$failing_pvcs" | jq -c '.[]?')

if [[ $(echo "$issues_json" | jq 'length') -eq 0 ]]; then
  issues_json=$(append_issue "$issues_json" \
    "VMS correlation completed for namespace \`${NAMESPACE}\`" \
    "No failing VAST PVCs required backend correlation. VMS endpoint ${VAST_VMS_ENDPOINT} responded successfully." \
    4 \
    "Re-run when PVC mount or binding failures occur to distinguish driver vs backend pressure.")
fi

write_issues "$OUTPUT_FILE" "$issues_json"
