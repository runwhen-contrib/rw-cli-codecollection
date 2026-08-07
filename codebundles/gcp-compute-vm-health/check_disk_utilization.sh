#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_disk_utilization.sh
#
# Checks boot and attached disk utilization for each target VM. Flags disks
# that exceed DISK_USAGE_THRESHOLD percent full or that are in a degraded /
# non-READY state. Disk usage percentage is read from Cloud Monitoring's
# 'agent.googleapis.com/disk/percent_used' metric (requires the Ops Agent);
# disk state is read directly from the instance configuration.
#
# Required env: GCP_PROJECT_ID, VM_NAME (or "All")
# Writes      : disk_issues.json (JSON array of issue objects)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gcp_vm_common.sh
. "$SCRIPT_DIR/gcp_vm_common.sh"

ISSUES_FILE="disk_issues.json"
rm -f "$ISSUES_FILE"

VM_LIST=$(select_target_vms)
count=$(printf '%s' "$VM_LIST" | jq length)

if [ "$count" -eq 0 ]; then
    finalize_issues
    echo "No standalone VMs matched VM_NAME='${VM_NAME}' in project ${GCP_PROJECT_ID}."
    exit 0
fi

echo "Checking disk utilization for ${count} VM(s) in project ${GCP_PROJECT_ID}."

printf '%s' "$VM_LIST" | jq -c '.[]' | while read -r vm; do
    name=$(printf '%s' "$vm" | jq -r '.name')
    zone=$(printf '%s' "$vm" | jq -r '.zone')
    instance_id=$(printf '%s' "$vm" | jq -r '.instance_id')

    inst=$(gcloud compute instances describe "$name" --zone="$zone" \
        --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")

    # 1) Disk state: flag any attached disk that is not READY.
    degraded=$(printf '%s' "$inst" | jq '[.disks[]? | select(.status != null and .status != "READY")] | length' 2>/dev/null || echo "0")
    if [ "$degraded" -gt 0 ]; then
        add_issue \
            "Compute VM \`${name}\` has ${degraded} disk(s) in a degraded state" \
            "VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) has ${degraded} attached disk(s) whose status is not READY, indicating a failing or detaching disk." \
            3 \
            "Inspect the disks attached to VM \`${name}\` at https://console.cloud.google.com/compute/disks and replace or re-attach any degraded disk." \
            "All disks attached to VM \`${name}\` should be in READY state." \
            "VM \`${name}\` has ${degraded} disk(s) not in READY state." \
            "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"degraded_disks\":${degraded},\"issue_type\":\"degraded_disk\"}"
    fi

    # 2) Disk usage percentage from Cloud Monitoring (best effort - Ops Agent).
    max_pct="0"
    if [ -n "$instance_id" ] && [ "$instance_id" != "null" ]; then
        ts_output=$(gcloud monitoring time-series list \
            --project="$GCP_PROJECT_ID" \
            --filter="metric.type=\"agent.googleapis.com/disk/percent_used\" AND resource.labels.instance_id=\"${instance_id}\"" \
            --format=json --limit=100 2>/dev/null || echo "[]")
        max_pct=$(printf '%s' "$ts_output" | jq '[.timeSeries[].points[-1].value.doubleValue // 0] | max // 0' 2>/dev/null || echo "0")
    fi

    threshold_num=$(printf '%s' "$DISK_USAGE_THRESHOLD" | awk '{printf "%d", $1}')
    max_pct_int=$(printf '%s' "$max_pct" | awk '{printf "%d", $1}')
    if [ "$max_pct_int" -ge "$threshold_num" ]; then
        add_issue \
            "Compute VM \`${name}\` has a disk above ${DISK_USAGE_THRESHOLD}% full (${max_pct_int}%)" \
            "A disk on VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) is at ${max_pct_int}% utilization, exceeding the DISK_USAGE_THRESHOLD of ${DISK_USAGE_THRESHOLD}%. The disk may fill up and cause service disruption." \
            4 \
            "Free up space on VM \`${name}\`, expand the boot disk ('gcloud compute disks resize'), or add and re-mount additional persistent disks to reduce utilization below ${DISK_USAGE_THRESHOLD}%." \
            "All disks on VM \`${name}\` should use less than ${DISK_USAGE_THRESHOLD}% of capacity." \
            "VM \`${name}\` has a disk at ${max_pct_int}% utilization." \
            "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"max_disk_usage_pct\":${max_pct_int},\"threshold\":${threshold_num},\"issue_type\":\"disk_filling\"}"
    else
        echo "  OK ${name}: max disk usage ${max_pct_int}% (threshold ${threshold_num}%)."
    fi
done

finalize_issues
echo "Disk utilization check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
exit 0
