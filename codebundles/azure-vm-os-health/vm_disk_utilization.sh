#!/bin/bash
# vm_disk_utilization.sh
#set -x
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP}
VM_INCLUDE_LIST=${VM_INCLUDE_LIST:-""}
VM_OMIT_LIST=${VM_OMIT_LIST:-""}
OUTPUT_FILE="vm-disk-utilization.json"

az account set --subscription "${SUBSCRIPTION_ID}"

# Get all VMs in the resource group
vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[].{name:name, resourceGroup:resourceGroup}" -o json)

if [ "$(echo $vms | jq length)" -eq "0" ]; then
    echo "No VMs found in resource group ${RESOURCE_GROUP}"
    exit 0
fi

shopt -s extglob

# Convert comma-separated lists to arrays
IFS=',' read -ra INCLUDE_PATTERNS <<< "$VM_INCLUDE_LIST"
IFS=',' read -ra OMIT_PATTERNS <<< "$VM_OMIT_LIST"

filter_vm() {
    local vm_name="$1"
    # If include list is set, only allow matching VMs
    if [ -n "$VM_INCLUDE_LIST" ]; then
        local match=0
        for pat in "${INCLUDE_PATTERNS[@]}"; do
            if [[ "$vm_name" == $pat ]]; then
                match=1
                break
            fi
        done
        [ $match -eq 0 ] && return 1
    fi
    # If omit list is set, skip matching VMs
    if [ -n "$VM_OMIT_LIST" ]; then
        for pat in "${OMIT_PATTERNS[@]}"; do
            if [[ "$vm_name" == $pat ]]; then
                return 1
            fi
        done
    fi
    return 0
}

while read -r vm; do
    vm_name=$(echo $vm | jq -r '.name')
    resource_group=$(echo $vm | jq -r '.resourceGroup')

    filter_vm "$vm_name" || continue

    vm_status=$(az vm get-instance-view -g $resource_group -n $vm_name \
        --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv)

    if [[ "$vm_status" != *"running"* ]]; then
        echo "Skipping VM $vm_name (status: $vm_status)" >&2
        continue
    fi

    echo "Checking disk utilization on $vm_name..." >&2
    disk_output=$(az vm run-command invoke \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "df -h")

    jq -n --arg name "$vm_name" --argjson output "$(echo "$disk_output" | jq '.')" \
        '{($name): {$output}}'
done < <(echo "$vms" | jq -c '.[]') > tmp_results.jsonl

cat tmp_results.jsonl

rm tmp_results.jsonl
