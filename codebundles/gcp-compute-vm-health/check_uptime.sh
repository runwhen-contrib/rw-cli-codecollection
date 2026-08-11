#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_uptime.sh
#
# Checks instance status and uptime for each target VM. Flags VMs that have
# been running longer than UPTIME_WARNING_DAYS (too long without a reboot) or
# that are in a degraded / non-running state.
#
# Required env: GCP_PROJECT_ID, VM_NAME (or "All")
# Writes      : uptime_issues.json (JSON array of issue objects)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gcp_vm_common.sh
. "$SCRIPT_DIR/gcp_vm_common.sh"

ISSUES_FILE="uptime_issues.json"
rm -f "$ISSUES_FILE"

# A failed API call or an unresolvable target records an issue (score 0) rather
# than returning an empty list, which the scorer would read as "nothing wrong".
if ! VM_LIST=$(resolve_target_vms "uptime and operational status"); then
    finalize_issues
    echo "Uptime check could not run for VM_NAME='${VM_NAME}' in project ${GCP_PROJECT_ID}."
    echo "Reason: $(resolve_reason)."
    echo "An issue was recorded so this is not scored as healthy. Nothing was checked."
    exit 0
fi
count=$(printf '%s' "$VM_LIST" | jq length)

if [ "$count" -eq 0 ]; then
    finalize_issues
    echo "No standalone VMs in project ${GCP_PROJECT_ID} (VM_NAME='All'); nothing to check."
    exit 0
fi

echo "Checking uptime and status for ${count} VM(s) in project ${GCP_PROJECT_ID}."

printf '%s' "$VM_LIST" | jq -c '.[]' | while read -r vm; do
    name=$(printf '%s' "$vm" | jq -r '.name')
    zone=$(printf '%s' "$vm" | jq -r '.zone')
    status=$(printf '%s' "$vm" | jq -r '.status')
    uptime_days=$(vm_uptime_days "$vm")

    if [ "$status" != "RUNNING" ]; then
        add_issue \
            "Compute VM \`${name}\` is not running (status: ${status})" \
            "Standalone VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) is in the \`${status}\` state. A stopped, terminated, or suspended VM cannot serve traffic." \
            3 \
            "Investigate and remediate VM \`${name}\`: start or recover it with 'gcloud compute instances start ${name} --zone=${zone} --project=${GCP_PROJECT_ID}' and confirm it reaches RUNNING state." \
            "VM \`${name}\` should be in the RUNNING state." \
            "VM \`${name}\` is in the ${status} state." \
            "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"status\":\"${status}\",\"issue_type\":\"vm_not_running\"}"
        echo "  ISSUE ${name} (${zone}): status=${status}, expected RUNNING."
    elif [ "$uptime_days" -ge "$UPTIME_WARNING_DAYS" ]; then
        add_issue \
            "Compute VM \`${name}\` has been running too long without a reboot (${uptime_days} days)" \
            "Standalone VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) has been running for approximately ${uptime_days} days, exceeding the UPTIME_WARNING_DAYS threshold of ${UPTIME_WARNING_DAYS} days. Long uptime may indicate that the VM has not applied kernel/reboot-required updates." \
            2 \
            "Plan a maintenance reboot for VM \`${name}\`: coordinate a window and run 'gcloud compute instances reset ${name} --zone=${zone} --project=${GCP_PROJECT_ID}' (or 'stop' then 'start') to apply pending reboots." \
            "VM \`${name}\` should be rebooted within ${UPTIME_WARNING_DAYS} days of last start." \
            "VM \`${name}\` has been running ${uptime_days} days without a reboot." \
            "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"uptime_days\":${uptime_days},\"issue_type\":\"overdue_reboot\"}"
        echo "  ISSUE ${name} (${zone}): status=${status}, uptime=${uptime_days} days >= UPTIME_WARNING_DAYS threshold of ${UPTIME_WARNING_DAYS}."
    else
        echo "  OK ${name} (${zone}): status=${status}, uptime=${uptime_days} days."
    fi
done

finalize_issues
echo "Uptime check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
exit 0
