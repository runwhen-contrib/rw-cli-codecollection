#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_TENANT
# AZ_SUBSCRIPTION
# AZ_RESOURCE_GROUP
# VMSCALESET

CPU_METRIC="Percentage CPU"
MEM_METRIC="Available Memory Bytes"

ALLOWED_CPU=80
ALLOWED_MEM=$((256 * 1048576)) # mb
METRIC_TOP=100

# Check if AZURE_RESOURCE_SUBSCRIPTION_ID is set, otherwise get the current subscription ID
if [ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }


ok=0
next_steps=()
cpu_data=$(az monitor metrics list --resource $VMSCALESET --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Compute/virtualMachineScaleSets --metric "$CPU_METRIC" --interval 5m --aggregation maximum --top $METRIC_TOP)
mem_data=$(az monitor metrics list --resource $VMSCALESET --resource-group $AZ_RESOURCE_GROUP --resource-type Microsoft.Compute/virtualMachineScaleSets --metric "$MEM_METRIC" --interval 5m --aggregation minimum --top $METRIC_TOP)

# Check if "maximum" is available in the JSON
if echo "$cpu_data" | jq -e '.value[].timeseries[].data[].maximum' >/dev/null; then
    for metric in $(echo "$cpu_data" | jq -r '.value[].timeseries[].data[].maximum | select(. != null and . != 0.0) | numbers'); do
        if (( $(echo "$metric > $ALLOWED_CPU" | bc -l) )); then
            echo "Found CPU usage above the allowed threshold: $ALLOWED_CPU for Azure VM Scaled Set $VMSCALESET in $AZ_RESOURCE_GROUP"
            next_steps+=("Increase Azure VM Scaled Set $VMSCALESET CPU\n")
            ok=1
            break
        fi
    done
else
    echo "No 'maximum' field available in the JSON data for CPU."
fi

# Check if "minimum" is available in the JSON
if echo "$mem_data" | jq -e '.value[].timeseries[].data[].minimum' >/dev/null; then
    # Loop through the "minimum" values
    for metric in $(echo "$mem_data" | jq -r '.value[].timeseries[].data[].minimum | select(. != null and . != 0.0)'); do
        if (( $(echo "$metric < $ALLOWED_MEM" | bc -l) )); then
            echo "Current memory available $metric is below the safety threshold: $ALLOWED_MEM for Azure VM Scaled Set $VMSCALESET in $AZ_RESOURCE_GROUP"
            next_steps+=("Increase Azure VM Scaled Set $VMSCALESET memory\n")
            ok=1
            break
        fi
    done
else
    echo "No 'minimum' field available in the JSON data for memory."
fi

if [ $ok -eq 1 ]; then
    echo "Error: The Azure VM Scaled Set $VMSCALESET in $AZ_RESOURCE_GROUP failed one or more key metric checks"
    echo ""
    echo "Next Steps:"
    echo -e "${next_steps[@]}"
    exit 1
else
    echo "Azure VM Scaled Set $VMSCALESET in $AZ_RESOURCE_GROUP passed all key metric checks"
    exit 0
fi