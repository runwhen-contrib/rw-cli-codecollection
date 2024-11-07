#!/bin/bash

# Initialize recommendations array
recommendations=""

convert_to_gigabytes() {
    size=$1
    number=$(echo $size | sed -E 's/([0-9]+(\.[0-9]+)?).*/\1/')
    unit=$(echo $size | sed -E 's/[0-9]+(\.[0-9]+)?(.*)/\2/')

    case $unit in
        Gi) echo $number ;;
        Ti) echo $(awk "BEGIN {print $number * 1024}") ;;
        Pi) echo $(awk "BEGIN {print $number * 1024 * 1024}") ;;
        *) echo "0" ;;
    esac
}

calculate_recommendation() {
    current_size=$1
    utilization=$2
    size_in_gb=$(convert_to_gigabytes $current_size)

    if ! [[ $size_in_gb =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "0"
        return
    fi

    recommended_size=0
    severity=""

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

    echo "$recommended_size $severity"
}

# Loop over all running pods in the specified namespace and context
for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim) | .metadata.name'); do
    pod_phase=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.status.phase')

    # Check if the pod is not in the "Running" phase
    if [ "$pod_phase" != "Running" ]; then
        recommendation="{ \"pod\": \"$pod\", \"recommended_action\": \"Investigate pod status for $pod as it is currently not running.\" }"
        recommendations="${recommendations:+$recommendations, }$recommendation"
        continue
    fi

    pod_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json)

    for pvc in $(echo "$pod_json" | jq -r '.spec.volumes[] | select(has("persistentVolumeClaim")) | .persistentVolumeClaim.claimName'); do
        volumeName=$(echo "$pod_json" | jq -r --arg pvcName "$pvc" '.spec.volumes[] | select(.persistentVolumeClaim.claimName == $pvcName) | .name')
        mountPath=$(echo "$pod_json" | jq -r --arg vol "$volumeName" '.spec.containers[].volumeMounts[] | select(.name == $vol) | .mountPath' | head -n 1)
        containerName=$(echo "$pod_json" | jq -r --arg vol "$volumeName" '.spec.containers[] | select(.volumeMounts[].name == $vol) | .name' | head -n 1)

        # Attempt to get disk usage, add recommendation if it fails
        disk_usage=$(${KUBERNETES_DISTRIBUTION_BINARY} exec $pod -n ${NAMESPACE} --context ${CONTEXT} -c $containerName -- df -h $mountPath 2>/dev/null | awk 'NR==2 {print $5}' | sed 's/%//')
        if [ $? -ne 0 ] || [ -z "$disk_usage" ]; then
            recommendation="{ \"pvc_name\":\"$pvc\", \"pod\": \"$pod\", \"volume_name\": \"$volumeName\", \"container_name\": \"$containerName\", \"mount_path\": \"$mountPath\", \"recommended_action\": \"Investigate pod $pod or PVC $pvc: unable to retrieve disk utilization.\" }"
            recommendations="${recommendations:+$recommendations, }$recommendation"
            continue
        fi

        disk_size=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.status.capacity.storage')
        recommendation_info=$(calculate_recommendation $disk_size $disk_usage)
        recommended_new_size=$(echo $recommendation_info | cut -d' ' -f1)
        severity=$(echo $recommendation_info | cut -d' ' -f2)

        if [ $recommended_new_size -ne 0 ]; then
            recommendation="{ \"pvc_name\":\"$pvc\", \"pod\": \"$pod\", \"volume_name\": \"$volumeName\", \"container_name\": \"$containerName\", \"mount_path\": \"$mountPath\", \"current_size\": \"$disk_size\", \"usage\": \"$disk_usage%\", \"recommended_size\": \"${recommended_new_size}Gi\", \"severity\": \"$severity\" }"
            recommendations="${recommendations:+$recommendations, }$recommendation"
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
