#!/bin/bash

# Environment Variables
# NAMESPACE
# CONTEXT

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

MAX_KILL=1
MEMORY_PRESSURE_AMOUNT=2147483648 # 2GB
POD_NAMES=$(kubectl get --context $CONTEXT pods -oname -n $NAMESPACE --field-selector=status.phase=Running)
echo "Starting random pod oomkill in namespace $NAMESPACE"
killed_count=0
for pod_name in $POD_NAMES; do
    # Roll a 50/50 chance
    if (( RANDOM % 2 == 0 )); then
        echo "Creating background process to OOMkill pod $pod_name by applying pressure to $MEMORY_PRESSURE_AMOUNT of memory..."
        kubectl exec --context $CONTEXT -n $NAMESPACE $pod_name -- /bin/sh -c 'for i in 1 2 3 4 5; do (while :; do dd if=/dev/zero of=/dev/null bs=2147483648  count=100 & done) & done'
        echo "Checking on pod..."
        sleep 3
        kubectl --context $CONTEXT describe $pod_name -n $NAMESPACE
        # Increment the killed count
        ((killed_count++))
    fi
    # Check if we have deleted 10 pods
    if (( killed_count >= MAX_KILL )); then
        break
    fi
done
echo "Current Pod States:"
kubectl get --context $CONTEXT pods -n $NAMESPACE
