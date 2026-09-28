#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE
# Finds pods using VAST CSI volumes with mount / VolumeAttachment failures.
# Writes JSON array to pod_mount_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="pod_mount_issues.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-csi-common.sh
source "${SCRIPT_DIR}/vast-csi-common.sh"

issues_json='[]'

print_report() {
  { set +x; } 2>/dev/null || true
  echo
  echo "=== Pod mount health for VAST volumes in '${NAMESPACE}' ==="
  k8s get pods -n "${NAMESPACE}" -o wide 2>/dev/null || true
  echo
  if [[ -s "$OUTPUT_FILE" ]]; then
    jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
  fi
}
trap print_report EXIT

vast_pvcs=$(list_vast_pvcs_json "${NAMESPACE}")
pvc_names=$(echo "$vast_pvcs" | jq -r '.items[].metadata.name // empty')

if [[ -z "$pvc_names" ]]; then
  all_pvcs=$(k8s get pvc -n "${NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
  pvc_names=$(while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    is_vast_pvc_json "$line" && echo "$line" | jq -r '.metadata.name'
  done < <(echo "$all_pvcs" | jq -c '.items[]?'))
fi

if [[ -z "$pvc_names" ]]; then
  write_issues "$OUTPUT_FILE" "$issues_json"
  exit 0
fi

while IFS= read -r pvc; do
  [[ -z "$pvc" ]] && continue
  pods_using=$(k8s get pods -n "${NAMESPACE}" -o json 2>/dev/null | jq -r --arg pvc "$pvc" '
    .items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $pvc) | .metadata.name
  ')
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    pod_json=$(k8s get pod "$pod" -n "${NAMESPACE}" -o json 2>/dev/null || echo '{}')
    phase=$(echo "$pod_json" | jq -r '.status.phase // "Unknown"')
    mount_fail=$(echo "$pod_json" | jq -r '
      [.status.containerStatuses[]?.state.waiting.reason? // empty,
       .status.initContainerStatuses[]?.state.waiting.reason? // empty] |
      map(select(. == "ContainerCreating" or . == "CreateContainerError")) | length
    ')

    not_ready=$(echo "$pod_json" | jq -r '
      ([.status.conditions[]? | select(.type=="Ready") | .status][0] // "False")
    ')

    if [[ "$phase" == "Pending" || "$not_ready" == "False" ]]; then
      issues_json=$(append_issue "$issues_json" \
        "Pod \`${pod}\` using VAST PVC \`${pvc}\` is not running/ready" \
        "Pod phase=${phase}, ready=${not_ready}, mount-related waits=${mount_fail} in namespace ${NAMESPACE}." \
        3 \
        "Describe pod ${pod} and check for FailedMount / FailedAttachVolume events. Inspect CSI node logs on the scheduled node.")
    fi

    events=$(k8s get events -n "${NAMESPACE}" --field-selector "involvedObject.name=${pod}" -o json 2>/dev/null || echo '{"items":[]}')
    while IFS= read -r ev; do
      [[ -z "$ev" ]] && continue
      msg=$(echo "$ev" | jq -r '.message')
      reason=$(echo "$ev" | jq -r '.reason')
      if echo "$msg $reason" | grep -qiE 'mount|publish|attach|volume|nfs|vast|csi'; then
        issues_json=$(append_issue "$issues_json" \
          "Mount-related event for pod \`${pod}\` (PVC \`${pvc}\`)" \
          "Event reason=${reason}: ${msg}" \
          3 \
          "Review VolumeAttachment objects and CSI node logs. Correlate with NFS xprt metrics if mounts hang.")
      fi
    done < <(echo "$events" | jq -c '.items[]? | select(.type == "Warning")')
  done <<< "$pods_using"
done <<< "$pvc_names"

# VolumeAttachment issues for VAST PVs in this namespace
vas=$(k8s get volumeattachment -o json 2>/dev/null || echo '{"items":[]}')
while IFS= read -r va; do
  [[ -z "$va" ]] && continue
  attached=$(echo "$va" | jq -r '.status.attached // false')
  err=$(echo "$va" | jq -r '.status.attachError.message // empty')
  pv=$(echo "$va" | jq -r '.spec.source.persistentVolumeName // empty')
  pod_ref=$(echo "$va" | jq -r '.spec.source.inlineVolumeSpec.claimRef.name // empty')
  driver=$(echo "$va" | jq -r '.spec.attacher // empty')

  [[ "$driver" != "csi.vastdata.com" ]] && continue
  [[ -n "$pod_ref" ]] && ! echo "$pvc_names" | grep -qx "$pod_ref" && continue

  if [[ "$attached" != "true" || -n "$err" ]]; then
    issues_json=$(append_issue "$issues_json" \
      "VolumeAttachment failure for VAST PV \`${pv:-unknown}\`" \
      "attached=${attached}, error=${err:-none}, claimRef=${pod_ref:-n/a}." \
      2 \
      "Describe volumeattachment and verify node driver registrar health. Check for stale attachments after node drains.")
  fi
done < <(echo "$vas" | jq -c '.items[]?')

write_issues "$OUTPUT_FILE" "$issues_json"
