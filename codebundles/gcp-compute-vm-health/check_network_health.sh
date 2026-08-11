#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# check_network_health.sh
#
# Verifies network health for each target VM: internal/external IP assignment,
# network tag consistency, and visible indicators of packet loss or traffic
# anomalies (Cloud Monitoring agent network metrics).
#
# Required env: GCP_PROJECT_ID, VM_NAME (or "All")
# Writes      : network_issues.json (JSON array of issue objects)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./gcp_vm_common.sh
. "$SCRIPT_DIR/gcp_vm_common.sh"

ISSUES_FILE="network_issues.json"
rm -f "$ISSUES_FILE"

# A failed API call or an unresolvable target records an issue (score 0) rather
# than returning an empty list, which the scorer would read as "nothing wrong".
if ! VM_LIST=$(resolve_target_vms "network health"); then
    finalize_issues
    echo "Network health check could not run for VM_NAME='${VM_NAME}' in project ${GCP_PROJECT_ID}."
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

echo "Checking network health for ${count} VM(s) in project ${GCP_PROJECT_ID}."

printf '%s' "$VM_LIST" | jq -c '.[]' | while read -r vm; do
    name=$(printf '%s' "$vm" | jq -r '.name')
    zone=$(printf '%s' "$vm" | jq -r '.zone')
    instance_id=$(printf '%s' "$vm" | jq -r '.instance_id')

    inst=$(gcloud compute instances describe "$name" --zone="$zone" \
        --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "{}")

    nif_count=$(printf '%s' "$inst" | jq '[.networkInterfaces[]?] | length' 2>/dev/null || echo "0")
    ext_ips=$(printf '%s' "$inst" | jq '[.networkInterfaces[]?.accessConfigs[]? | select(.natIP != null and .natIP != "")] | length' 2>/dev/null || echo "0")

    if [ "$nif_count" -eq 0 ]; then
        add_issue \
            "Compute VM \`${name}\` has no network interfaces configured" \
            "VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) has no network interfaces, so it has no connectivity." \
            3 \
            "Attach a network interface / VPC to VM \`${name}\` at https://console.cloud.google.com/compute/instances and confirm a subnet is assigned." \
            "VM \`${name}\` should have at least one network interface with a subnet." \
            "VM \`${name}\` has ${nif_count} network interfaces." \
            "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"network_interfaces\":${nif_count},\"issue_type\":\"no_network_interface\"}"
        echo "  ISSUE ${name} (${zone}): no network interfaces configured."
    else
        echo "  OK ${name} (${zone}): ${nif_count} network interface(s), ${ext_ips} external IP assignment(s)."
    fi

    # Network tag consistency: flag VMs that define network tags but have no
    # matching firewall rules, which usually indicates an open/misconfigured VPC.
    tag_count=$(printf '%s' "$inst" | jq '[.tags.items[]?] | length' 2>/dev/null || echo "0")
    if [ "$tag_count" -gt 0 ]; then
        tag_rules=$(gcloud compute firewall-rules list \
            --project="$GCP_PROJECT_ID" --format="json" 2>/dev/null | \
            jq --argjson ntags "$(printf '%s' "$inst" | jq '[.tags.items[]?]' 2>/dev/null || echo '[]')" \
               '[.[] | select(any(.targetTags[]?; . as $t | $ntags | index($t)))] | length' 2>/dev/null || echo "0")
        if [ "$tag_rules" -eq 0 ]; then
            add_issue \
                "Compute VM \`${name}\` has network tags but no matching firewall rules" \
                "VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) defines ${tag_count} network tag(s) but no firewall rule targets them, which may leave it unreachable or misconfigured." \
                3 \
                "Review the firewall rules in project \`${GCP_PROJECT_ID}\` and ensure the intended rules target VM \`${name}\`'s tags, or remove unused tags." \
                "Firewall rules matching VM \`${name}\`'s tags should exist." \
                "VM \`${name}\` has ${tag_count} tags and ${tag_rules} matching firewall rules." \
                "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"tags\":${tag_count},\"matching_firewall_rules\":${tag_rules},\"issue_type\":\"tag_firewall_mismatch\"}"
            echo "  ISSUE ${name} (${zone}): ${tag_count} network tag(s) but no firewall rule targets them."
        else
            echo "  OK ${name} (${zone}): ${tag_count} network tag(s), ${tag_rules} matching firewall rule(s)."
        fi
    else
        echo "  OK ${name} (${zone}): no network tags defined."
    fi

    # Packet loss / traffic anomaly indicator via Ops Agent network metrics.
    if [ -n "$instance_id" ] && [ "$instance_id" != "null" ]; then
        drop_output=$(gcloud monitoring time-series list \
            --project="$GCP_PROJECT_ID" \
            --filter="metric.type=\"agent.googleapis.com/interface/tx_dropped_packets\" AND resource.labels.instance_id=\"${instance_id}\"" \
            --format=json --limit=100 2>/dev/null || echo "[]")
        total_drops=$(printf '%s' "$drop_output" | jq '[.timeSeries[].points[-1].value.int64Value // 0] | add // 0' 2>/dev/null || echo "0")
        drops_num=$(printf '%s' "$total_drops" | awk '{printf "%d", $1}')
        if [ "$drops_num" -gt 0 ]; then
            add_issue \
                "Compute VM \`${name}\` is dropping network packets (${drops_num} drops)" \
                "VM \`${name}\` in project \`${GCP_PROJECT_ID}\` (zone \`${zone}\`) has observed ${drops_num} dropped transmitted packets, which may indicate NIC saturation, misconfiguration, or network path issues." \
                3 \
                "Inspect the network dashboards for VM \`${name}\`, check interface queues and bandwidth, and review the project firewall/VPC configuration." \
                "VM \`${name}\` should show no dropped packets." \
                "VM \`${name}\` has ${drops_num} dropped packets reported by the agent." \
                "{\"vm\":\"${name}\",\"zone\":\"${zone}\",\"dropped_packets\":${drops_num},\"issue_type\":\"packet_loss\"}"
            echo "  ISSUE ${name} (${zone}): ${drops_num} dropped transmitted packet(s) reported."
        else
            echo "  OK ${name} (${zone}): no dropped packets reported."
        fi
    else
        echo "  -- ${name} (${zone}): no instance id available; packet-drop metrics were not queried."
    fi
done

finalize_issues
echo "Network health check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
exit 0
