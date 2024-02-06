#!/bin/bash

# Initialize recommendations array
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
