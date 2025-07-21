#!/bin/bash
# vm_last_patch_check.sh

SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP}
VM_NAME=${VM_NAME:-""}
OUTPUT_FILE="vm-last-patch.json"

az account set --subscription "${SUBSCRIPTION_ID}"

if [ -n "${VM_NAME}" ]; then
    vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[?name=='${VM_NAME}'].{name:name, resourceGroup:resourceGroup}" -o json)
else
    vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[].{name:name, resourceGroup:resourceGroup}" -o json)
fi

if [ "$(echo $vms | jq length)" -eq "0" ]; then
    echo "No VMs found in resource group ${RESOURCE_GROUP}"
    exit 0
fi

while read -r vm; do
    vm_name=$(echo $vm | jq -r '.name')
    resource_group=$(echo $vm | jq -r '.resourceGroup')

    vm_status=$(az vm get-instance-view -g $resource_group -n $vm_name \
        --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv)

    if [[ "$vm_status" != *"running"* ]]; then
        echo "Skipping VM $vm_name (status: $vm_status)" >&2
        continue
    fi

    echo "Checking last patch status on $vm_name..." >&2
    patch_output=$(az vm run-command invoke \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "if command -v apt-get &>/dev/null; then apt list --upgradable 2>/dev/null | grep -v Listing; elif command -v yum &>/dev/null; then yum check-update; else echo 'Unknown OS'; fi")

    jq -n --arg name "$vm_name" --argjson output "$(echo "$patch_output" | jq '.')" \
        '{($name): {"output": $output}}'
done < <(echo "$vms" | jq -c '.[]') > tmp_results.jsonl

cat tmp_results.jsonl

#jq -s '.' tmp_results.jsonl > "$OUTPUT_FILE"
rm tmp_results.jsonl