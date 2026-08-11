#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# generate_vm_summary.sh
#
# Aggregates per-VM health findings into a consolidated summary JSON per VM
# (status, uptime, disk, machine type) and an overall verdict. Also flags any
# standalone VM that is not RUNNING as a summary-level issue.
#
# Required env: GCP_PROJECT_ID
# Writes      : vm_health_summary.json
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gcp_vm_common.sh
. "$SCRIPT_DIR/gcp_vm_common.sh"

ISSUES_FILE="summary_issues.json"
rm -f "$ISSUES_FILE"

VM_LIST=$(discover_standalone_vms)
count=$(printf '%s' "$VM_LIST" | jq length)

echo "Generating health summary for ${count} standalone VM(s) in project ${GCP_PROJECT_ID}."

SUMMARY=$(printf '%s' "$VM_LIST" | jq -c '[
    .[] | {
        name: .name,
        zone: .zone,
        status: .status,
        machine_type: .machine_type,
        uptime_days: (.last_start_timestamp | if . == null or . == "null" then 0 else ((now - (fromdateiso8601 // now)) / 86400 | floor) end),
        verdict: (if .status == "RUNNING" then "ok" else "degraded" end)
    }
]')

echo "$SUMMARY" | jq '.' > vm_health_summary.json

# If the overall intent is a project-scoped summary, add a summary issue for
# any VM that is not RUNNING so the runbook surfaces a high-level problem.
printf '%s' "$SUMMARY" | jq -c '.[] | select(.status != "RUNNING")' | while read -r vm_sum; do
    name=$(printf '%s' "$vm_sum" | jq -r '.name')
    zone=$(printf '%s' "$vm_sum" | jq -r '.zone')
    status=$(printf '%s' "$vm_sum" | jq -r '.status')
    add_issue \
        "Compute VM \`${name}\` is unhealthy (status: ${status})" \
        "Health summary for project \`${GCP_PROJECT_ID}\` shows VM \`${name}\` (zone \`${zone}\`) is not running (status: ${status}), so the VM is marked degraded. Total unhealthy VMs: $(printf '%s' "$SUMMARY" | jq '[.[] | select(.status != "RUNNING")] | length')." \
        3 \
        "Investigate VM \`${name}\` and bring it to RUNNING state; review the per-VM uptime/patch/disk/network/console checks for this VM." \
        "All standalone VMs in project \`${GCP_PROJECT_ID}\` should be RUNNING." \
        "VM \`${name}\` is in ${status} state." \
        "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"status\":\"${status}\",\"issue_type\":\"unhealthy_vm\"}"
done

finalize_issues

total=$(printf '%s' "$SUMMARY" | jq length)
unhealthy=$(printf '%s' "$SUMMARY" | jq '[.[] | select(.status != "RUNNING")] | length')
echo "Health summary generated for ${total} VM(s): ${unhealthy} unhealthy, $((total - unhealthy)) healthy."
printf '%s' "$SUMMARY" | jq -r '.[] | "\(.name)\tstatus=\(.status)\tuptime_days=\(.uptime_days)\tverdict=\(.verdict)"'
echo "Results saved to vm_health_summary.json"
exit 0
