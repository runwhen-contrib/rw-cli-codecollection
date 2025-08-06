#!/bin/bash
# vm_uptime_check.sh

SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP}
VM_INCLUDE_LIST=${VM_INCLUDE_LIST:-""}
VM_OMIT_LIST=${VM_OMIT_LIST:-""}
OUTPUT_FILE="vm-uptime.json"
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-5}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-30}
VM_STATUS_TIMEOUT=${VM_STATUS_TIMEOUT:-10}
COMMAND_TIMEOUT=${COMMAND_TIMEOUT:-45}

# Test Azure CLI authentication early
if ! az account show --subscription "${SUBSCRIPTION_ID}" >/dev/null 2>&1; then
    echo "Failed to authenticate with Azure CLI for subscription ${SUBSCRIPTION_ID}" >&2
    echo '{"error": "Azure authentication failed"}' 
    exit 1
fi

az account set --subscription "${SUBSCRIPTION_ID}"

vms=$(az vm list --resource-group "${RESOURCE_GROUP}" --query "[].{name:name, resourceGroup:resourceGroup, osType:storageProfile.osDisk.osType}" -o json 2>/dev/null)

if [ $? -ne 0 ] || [ "$(echo $vms | jq length)" -eq "0" ]; then
    echo "No VMs found in resource group ${RESOURCE_GROUP} or failed to list VMs" >&2
    echo "{}"
    exit 0
fi

shopt -s extglob
IFS=',' read -ra INCLUDE_PATTERNS <<< "$VM_INCLUDE_LIST"
IFS=',' read -ra OMIT_PATTERNS <<< "$VM_OMIT_LIST"

filter_vm() {
    local vm_name="$1"
    local os_type="$2"
    
    # Filter out Windows machines - only process Linux VMs
    if [ "$os_type" != "Linux" ]; then
        echo "Skipping Windows VM $vm_name (OS type: $os_type)" >&2
        return 1
    fi
    
    # If include list is set, only allow matching VMs
    if [ -n "$VM_INCLUDE_LIST" ]; then
        local match=0
        for pat in "${INCLUDE_PATTERNS[@]}"; do
            if [[ "$vm_name" == $pat ]]; then
                match=1
                break
            fi
        done
        if [ $match -eq 0 ]; then
            echo "Skipping VM $vm_name (not in include list)" >&2
            return 2  # Different return code for not included
        fi
    fi
    # If omit list is set, skip matching VMs
    if [ -n "$VM_OMIT_LIST" ]; then
        for pat in "${OMIT_PATTERNS[@]}"; do
            if [[ "$vm_name" == $pat ]]; then
                echo "Skipping VM $vm_name (in omit list)" >&2
                return 3  # Different return code for omitted
            fi
        done
    fi
    return 0
}

# Function to check a single VM
check_vm_uptime() {
    local vm_name="$1"
    local resource_group="$2"
    local temp_file="$3"

    # Check VM power state first with shorter timeout
    vm_status=$(timeout $VM_STATUS_TIMEOUT az vm get-instance-view -g "$resource_group" -n "$vm_name" \
        --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" -o tsv 2>/dev/null)

    if [ $? -ne 0 ]; then
        # Connection/auth issue - create issue but don't fail
        echo "Failed to get VM status for $vm_name - connection or authentication issue" >&2
        jq -n --arg name "$vm_name" --arg stderr "Failed to get VM status - connection or authentication issue" --arg status "Connection Failed" --arg code "ConnectionError" \
            '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
        return
    fi
    
    if [[ "$vm_status" != *"running"* ]]; then
        echo "Skipping VM $vm_name (status: $vm_status)" >&2
        jq -n --arg name "$vm_name" --arg stderr "VM not running (status: $vm_status)" --arg status "$vm_status" --arg code "VMNotRunning" \
            '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
        return
    fi

    echo "Checking uptime on $vm_name..." >&2
    uptime_output=$(timeout $COMMAND_TIMEOUT az vm run-command invoke \
        --resource-group "$resource_group" \
        --name "$vm_name" \
        --command-id RunShellScript \
        --scripts "
        # Get uptime in seconds
        uptime_sec=\$(cat /proc/uptime | awk '{print \$1}')
        
        # Convert to human readable format
        days=\$(echo \"\$uptime_sec\" | awk '{printf \"%d\", \$1/86400}')
        hours=\$(echo \"\$uptime_sec\" | awk '{printf \"%d\", (\$1 % 86400) / 3600}')
        minutes=\$(echo \"\$uptime_sec\" | awk '{printf \"%d\", (\$1 % 3600) / 60}')
        
        echo \"System Uptime: \$days days, \$hours hours, \$minutes minutes\"
        echo \"Uptime (decimal days): \$(echo \"\$uptime_sec\" | awk '{printf \"%.2f\", \$1/86400}')\"
        echo \"Uptime (total seconds): \$uptime_sec\"
        
        # Also show load averages for additional context
        echo \"Load Averages: \$(cat /proc/loadavg | awk '{print \$1, \$2, \$3}')\"
        " 2>/dev/null)

    if [ $? -ne 0 ]; then
        echo "Failed to execute uptime check command on $vm_name - timeout or connection issue" >&2
        jq -n --arg name "$vm_name" --arg stderr "Failed to execute uptime check command - timeout or connection issue" --arg status "Command Failed" --arg code "CommandTimeout" \
            '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
        return
    fi

    # Extract the message from the Azure response
    message=$(echo "$uptime_output" | jq -r '.value[0].message' 2>/dev/null)
    
    if [ "$message" = "null" ] || [ -z "$message" ]; then
        echo "Invalid response from Azure run-command for $vm_name" >&2
        jq -n --arg name "$vm_name" --arg stderr "Invalid response from Azure run-command" --arg status "Invalid Response" --arg code "InvalidResponse" \
            '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
        return
    fi
    
    # Extract stdout and stderr from the message
    stdout=$(echo "$message" | awk '/\[stdout\]/{flag=1;next}/\[stderr\]/{flag=0}flag' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    stderr=$(echo "$message" | awk '/\[stderr\]/{flag=1}flag' | sed '1d' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    # Get status and code from Azure response
    status=$(echo "$uptime_output" | jq -r '.value[0].displayStatus' 2>/dev/null)
    code=$(echo "$uptime_output" | jq -r '.value[0].code' 2>/dev/null)

    jq -n --arg name "$vm_name" --arg stdout "$stdout" --arg stderr "$stderr" --arg status "$status" --arg code "$code" \
        '{($name): {stdout: $stdout, stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
}

# Create temp directory for parallel processing
temp_dir=$(mktemp -d)
trap "rm -rf $temp_dir" EXIT

results="{}"
job_count=0
declare -a pids=()
declare -a temp_files=()

while read -r vm; do
    vm_name=$(echo $vm | jq -r '.name')
    resource_group=$(echo $vm | jq -r '.resourceGroup')
    os_type=$(echo $vm | jq -r '.osType')

    # Check if VM should be filtered and why
    filter_vm "$vm_name" "$os_type"
    filter_result=$?
    
    if [ $filter_result -ne 0 ]; then
        # Create temp file for skipped VM result
        temp_file="$temp_dir/vm_${vm_name}.json"
        temp_files+=("$temp_file")
        
        case $filter_result in
            1) # Windows VM
                jq -n --arg name "$vm_name" --arg stderr "Windows VM skipped (OS type: $os_type)" --arg status "Skipped" --arg code "WindowsVM" \
                    '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
                ;;
            2) # Not in include list
                jq -n --arg name "$vm_name" --arg stderr "VM not in include list" --arg status "Skipped" --arg code "NotIncluded" \
                    '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
                ;;
            3) # In omit list
                jq -n --arg name "$vm_name" --arg stderr "VM in omit list" --arg status "Skipped" --arg code "Omitted" \
                    '{($name): {stdout: "", stderr: $stderr, status: $status, code: $code}}' > "$temp_file"
                ;;
        esac
        continue
    fi

    # Create temp file for this VM's result
    temp_file="$temp_dir/vm_${vm_name}.json"
    temp_files+=("$temp_file")

    # Start background job
    check_vm_uptime "$vm_name" "$resource_group" "$temp_file" &
    pids+=($!)
    ((job_count++))

    # Limit parallel jobs
    if [ $job_count -ge $MAX_PARALLEL_JOBS ]; then
        # Wait for one job to complete
        wait ${pids[0]}
        pids=("${pids[@]:1}")  # Remove first PID
        ((job_count--))
    fi
done < <(echo "$vms" | jq -c '.[]')

# Wait for all remaining jobs
for pid in "${pids[@]}"; do
    wait $pid
done

# Combine all results
for temp_file in "${temp_files[@]}"; do
    if [ -f "$temp_file" ]; then
        vm_result=$(cat "$temp_file")
        results=$(jq -s '.[0] * .[1]' <(echo "$results") <(echo "$vm_result"))
    fi
done

echo "$results"