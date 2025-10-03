#!/bin/bash

# Initialize recommendations array
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

recommendations=""

convert_to_gigabytes() {
    size=$1

    # Extract the number and the unit (e.g., 10Gi, 1Ti)
    number=$(echo $size | sed -E 's/([0-9]+(\.[0-9]+)?).*/\1/')
    unit=$(echo $size | sed -E 's/[0-9]+(\.[0-9]+)?(.*)/\2/')

    # Convert to gigabytes based on the unit
    case $unit in
        Gi)
            echo $number
            ;;
        Ti)
            echo $(awk "BEGIN {print $number * 1024}")
            ;;
        Pi)
            echo $(awk "BEGIN {print $number * 1024 * 1024}")
            ;;
        *)
            echo "0"
            ;;
    esac
}

calculate_recommendation() {
    current_size=$1
    utilization=$2

    # Convert size to GB
    size_in_gb=$(convert_to_gigabytes $current_size)

    # Ensure the size is a number
    if ! [[ $size_in_gb =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "0"
        return
    fi

    recommended_size=0
    severity=""

    # Calculate the recommended size and assign severity based on utilization
    if [ "$utilization" -ge 100 ]; then
        recommended_size=$(awk "BEGIN {print int(2 * $size_in_gb + 0.5)}")
        severity="1"
    elif [ "$utilization" -ge 95 ]; then
        recommended_size=$(awk "BEGIN {print int(1.75 * $size_in_gb + 0.5)}")
        severity="2"
    elif [ "$utilization" -ge 90 ]; then
        recommended_size=$(awk "BEGIN {print int(1.5 * $size_in_gb + 0.5)}")
        severity="3"
    elif [ "$utilization" -ge 80 ]; then
        recommended_size=$(awk "BEGIN {print int(1.25 * $size_in_gb + 0.5)}")
        severity="4"
    fi

    # Output the recommended size and severity
    echo "$recommended_size $severity"
}

# Loop over all running pods in the specified namespace and context
for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim) | select(.status.phase=="Running") | .metadata.name'); do
    # Get the entire JSON of the pod
    pod_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json)

    # Loop over all PVCs used by the pod
    for pvc in $(echo "$pod_json" | jq -r '.spec.volumes[] | select(has("persistentVolumeClaim")) | .persistentVolumeClaim.claimName'); do
        # Get the volume name associated with the PVC
        volumeName=$(echo "$pod_json" | jq -r --arg pvcName "$pvc" '.spec.volumes[] | select(.persistentVolumeClaim.claimName == $pvcName) | .name')

        # Get the first mount path and container name associated with the volume
        mountPath=$(echo "$pod_json" | jq -r --arg vol "$volumeName" '.spec.containers[].volumeMounts[] | select(.name == $vol) | .mountPath' | head -n 1)
        containerName=$(echo "$pod_json" | jq -r --arg vol "$volumeName" '.spec.containers[] | select(.volumeMounts[].name == $vol) | .name' | head -n 1)

        # Get disk usage
        disk_usage=$(${KUBERNETES_DISTRIBUTION_BINARY} exec $pod -n ${NAMESPACE} --context ${CONTEXT} -c $containerName -- df -h $mountPath | awk 'NR==2 {print $5}' | sed 's/%//')
        disk_size=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.status.capacity.storage')

        # Calculate recommendation and severity
        recommendation_info=$(calculate_recommendation $disk_size $disk_usage)
        recommended_new_size=$(echo $recommendation_info | cut -d' ' -f1)
        severity=$(echo $recommendation_info | cut -d' ' -f2)

        if [ $recommended_new_size -ne 0 ]; then
            # Format the recommendation as JSON
            recommendation="{ \"remediation_type\":\"pvc_increase\", \"object_type\":\"PersistentVolumeClaim\", \"object_name\":\"$pvc\", \"pod\": \"$pod\", \"volume_name\": \"$volumeName\", \"container_name\": \"$containerName\", \"mount_path\": \"$mountPath\", \"current_size\": \"$disk_size\", \"usage\": \"$disk_usage%\", \"recommended_size\": \"${recommended_new_size}Gi\", \"severity\": \"$severity\" }"
            # Add the recommendation to the array
            if [ -z "$recommendations" ]; then
                recommendations="$recommendation"
            else
                recommendations="$recommendations, $recommendation"
            fi
        fi
    done
done


# Outputting recommendations as JSON
if [ -n "$recommendations" ]; then
    echo "Recommended Next Steps:"
    echo "[$recommendations]" | jq .
else
    echo "No recommendations."
fi
