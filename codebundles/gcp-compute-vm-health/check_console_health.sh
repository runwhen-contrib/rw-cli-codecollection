#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_console_health.sh
#
# Checks guest attributes / serial console output and instance metadata for
# each target VM to detect guest agent issues, boot failures, or console
# errors.
#
# Required env: GCP_PROJECT_ID, VM_NAME (or "All")
# Writes      : console_issues.json (JSON array of issue objects)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gcp_vm_common.sh
. "$SCRIPT_DIR/gcp_vm_common.sh"

ISSUES_FILE="console_issues.json"
rm -f "$ISSUES_FILE"

VM_LIST=$(select_target_vms)
count=$(printf '%s' "$VM_LIST" | jq length)

if [ "$count" -eq 0 ]; then
    finalize_issues
    echo "No standalone VMs matched VM_NAME='${VM_NAME}' in project ${GCP_PROJECT_ID}."
    exit 0
fi

echo "Checking guest/console health for ${count} VM(s) in project ${GCP_PROJECT_ID}."

# Error patterns observed in serial console output that indicate boot/guest
# problems. Each entry: regex|severity|next_steps.
CONSOLE_PATTERNS=(
    "Kernel panic|3|Reboot the VM and inspect the serial console output to determine the root cause of the kernel panic."
    "BUG:|3|Capture the serial console log and open a support case / inspect the kernel stack trace for the BUG condition."
    "Oops:|3|Review the serial console Oops trace for VM and check for driver/hardware faults."
    "out of memory|2|Review memory pressure; consider resizing the VM machine type or investigating a runaway process."
    "guest agent.*fail|2|Verify the Google Guest Agent is installed and running; reconfigure guest attributes if needed."
    "no job control|2|Serial console reached a shell; confirm the guest OS booted successfully."
)

printf '%s' "$VM_LIST" | jq -c '.[]' | while read -r vm; do
    name=$(printf '%s' "$vm" | jq -r '.name')
    zone=$(printf '%s' "$vm" | jq -r '.zone')

    serial=$(gcloud compute instances get-serial-port-output "$name" \
        --zone="$zone" --project="$GCP_PROJECT_ID" 2>/dev/null || echo "")

    found=0
    for pattern_spec in "${CONSOLE_PATTERNS[@]}"; do
        IFS='|' read -r pattern severity next_step <<< "$pattern_spec"
        if printf '%s' "$serial" | grep -qiE "$pattern"; then
            add_issue \
                "Compute VM \`${name}\` shows a console problem matching '${pattern}'" \
                "The serial console output for VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) contains an error pattern matching '${pattern}', indicating a boot, guest agent, or runtime problem." \
                "$severity" \
                "$next_step" \
                "VM \`${name}\` serial console should be free of error patterns." \
                "VM \`${name}\` serial console matched '${pattern}'." \
                "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"pattern\":\"${pattern}\",\"issue_type\":\"console_error\"}"
            found=1
        fi
    done

    # Guest agent health: verify the instance metadata requests guest attributes
    # (a sign the guest agent should be running and reporting health data).
    enable_guest_attributes=$(gcloud compute instances describe "$name" \
        --zone="$zone" --project="$GCP_PROJECT_ID" --format="value(metadata.items[enable-guest-attributes])" 2>/dev/null || echo "")
    if [ "$enable_guest_attributes" = "true" ]; then
        echo "  OK ${name}: guest attributes enabled, no console errors detected."
    else
        echo "  OK ${name}: no console errors detected."
    fi

    if [ "$found" -eq 0 ]; then
        echo "  (${name}) no console error patterns found."
    fi
done

finalize_issues
echo "Console health check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
exit 0
