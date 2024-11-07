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

get_top_level_owner() {
    # Start with the pod's immediate owner reference
    resource_kind=$1
    resource_name=$2

    while [ "$resource_kind" == "ReplicaSet" ]; do
        # Fetch the ReplicaSet's owner reference
        owner_info=$(${KUBERNETES_DISTRIBUTION_BINARY} get replicaset $resource_name -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.metadata.ownerReferences[0] | "\(.kind)/\(.name)"')
        resource_kind=$(echo "$owner_info" | cut -d'/' -f1)
        resource_name=$(echo "$owner_info" | cut -d'/' -f2)
    done

    echo "$resource_kind/$resource_name"
}

# Loop over all running pods in the specified namespace and context
for pod in $(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.items[] | select(.spec.volumes[]?.persistentVolumeClaim) | .metadata.name'); do
    pod_phase=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.status.phase')

    # Retrieve the pod's immediate owner reference (likely a ReplicaSet)
    initial_owner_info=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.metadata.ownerReferences[0] | "\(.kind)/\(.name)"')
    initial_owner_kind=$(echo "$initial_owner_info" | cut -d'/' -f1)
    initial_owner_name=$(echo "$initial_owner_info" | cut -d'/' -f2)

    # Follow the chain to get the top-level owner (Deployment, StatefulSet, etc.)
    top_level_owner=$(get_top_level_owner "$initial_owner_kind" "$initial_owner_name")
    top_level_owner_kind=$(echo "$top_level_owner" | cut -d'/' -f1)
    top_level_owner_name=$(echo "$top_level_owner" | cut -d'/' -f2)

    # Check if the pod is not in the "Running" phase
    if [ "$pod_phase" != "Running" ]; then
        recommendation="{ \"pod\": \"$pod\", \"owner_kind\": \"$top_level_owner_kind\", \"owner_name\": \"$top_level_owner_name\", \"next_steps\": \"Check $top_level_owner_kind \`$top_level_owner_name\` health\nInspect Pending Pods In Namespace \`$NAMESPACE\`\", \"title\": \"Pod `$pod` with PVC is running\", \"details\": \"Pod $pod, owned by $top_level_owner_kind $top_level_owner_name, is not in a running state.\", \"severity\": \"2\" }"
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
            recommendation="{ \"pvc_name\":\"$pvc\", \"pod\": \"$pod\", \"owner_kind\": \"$top_level_owner_kind\", \"owner_name\": \"$top_level_owner_name\", \"volume_name\": \"$volumeName\", \"container_name\": \"$containerName\", \"mount_path\": \"$mountPath\", \"next_steps\": \"Investigate $top_level_owner_kind or PVC $pvc: unable to retrieve disk utilization.\", \"title\": \"Disk Utilization Check Failed for $pvc\", \"details\": \"Unable to retrieve disk utilization for $pvc in pod $pod, owned by $top_level_owner_kind $top_level_owner_name.\", \"severity\": \"5\" }"
            recommendations="${recommendations:+$recommendations, }$recommendation"
            continue
        fi

        disk_size=$(${KUBERNETES_DISTRIBUTION_BINARY} get pvc $pvc -n ${NAMESPACE} --context ${CONTEXT} -o json | jq -r '.status.capacity.storage')
        recommendation_info=$(calculate_recommendation $disk_size $disk_usage)
        recommended_new_size=$(echo $recommendation_info | cut -d' ' -f1)
        severity=$(echo $recommendation_info | cut -d' ' -f2)

        if [ $recommended_new_size -ne 0 ]; then
            recommendation="{ \"pvc_name\":\"$pvc\", \"pod\": \"$pod\", \"owner_kind\": \"$top_level_owner_kind\", \"owner_name\": \"$top_level_owner_name\", \"volume_name\": \"$volumeName\", \"container_name\": \"$containerName\", \"mount_path\": \"$mountPath\", \"current_size\": \"$disk_size\", \"usage\": \"$disk_usage%\", \"recommended_size\": \"${recommended_new_size}Gi\", \"severity\": \"$severity\", \"title\": \"High Utilization on PVC $pvc\", \"details\": \"Current size: $disk_size, Utilization: ${disk_usage}%, Recommended new size: ${recommended_new_size}Gi. Owned by $top_level_owner_kind $top_level_owner_name.\", \"next_steps\": \"Expand PVC $pvc to ${recommended_new_size}Gi.\" }"
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
