#!/bin/bash

# Initialize recommendations array
declare -a recommendations

# Function to convert memory to Mi
convert_memory_to_mib() {
    local memory=$1

    # Extract the number and unit separately
    local number=${memory//[!0-9]/}
    local unit=${memory//[0-9]/}

    case $unit in
        Gi)
            echo $(( number * 1024 ))  # Convert Gi to Mi
            ;;
        Mi)
            echo $number  # Already in Mi
            ;;
        Ki)
            echo $(( number / 1024 ))  # Convert Ki to Mi
            ;;
        *)
            echo $(( number / (1024 * 1024) ))  # Convert bytes to Mi
            ;;
    esac
}

# Function to convert CPU to millicores
convert_cpu_to_millicores() {
    local cpu=$1
    if [[ $cpu =~ ^[0-9]+m$ ]]; then
        echo ${cpu%m}
    else
        echo $(($cpu * 1000))  # Convert CPU cores to millicores
    fi
}

# Function to extract target reference from VPA
get_vpa_target_ref() {
    local vpa_name=$1
    local namespace=$2

    local vpa_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get vpa "$vpa_name" -n "$namespace" --context "${CONTEXT}" -o json)
    echo "$vpa_json" | jq -r '.spec.targetRef | "\(.kind) \(.name)"'
}

# Function to get current CPU and Memory requests for the target object
get_current_requests() {
    local object_type=$1
    local object_name=$2
    local namespace=$3

    if [[ "$object_type" == "Deployment" ]]; then
        local target_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get "$object_type" "$object_name" -n "$namespace" --context "${CONTEXT}" -o json)
        echo "$target_json" | jq -r '.spec.template.spec.containers[] | .name as $name | .resources.requests | {container: $name, cpu: (.cpu // "0"), memory: (.memory // "0Mi")}'
    else
        echo "Unsupported target kind: $object_type"
    fi
}

# Function to analyze VPA and current configuration
analyze_vpa() {
    local vpa_name=$1
    local namespace=$2
    local vpa_item=$3

    # Fetch VPA target reference
    local target_ref=$(echo "$vpa_item" | jq -r '.spec.targetRef | "\(.kind) \(.name)"')
    read object_type object_name <<< "$target_ref"

    # Fetch current CPU and Memory requests
    local current_requests=$(get_current_requests "$object_type" "$object_name" "$namespace")

    # Extract VPA recommendations from vpa_item
    local vpa_recommendations=$(echo "$vpa_item" | jq -r '.status.recommendation.containerRecommendations[] | {container: .containerName, targetCpu: .target.cpu, targetMemory: .target.memory}')

    # Define a threshold for significant deviation (10%)
    local threshold=20

    # Function to round values
    round_up() {
        local value=$1
        local multiple=$2
        echo $(( (value + multiple - 1) / multiple * multiple ))
    }

    # Analyze and generate recommendations
    while IFS= read -r request; do
        local container=$(echo "$request" | jq -r '.container')
        local current_cpu_request=$(echo "$request" | jq -r '.cpu')
        local current_memory_request=$(echo "$request" | jq -r '.memory')

        # Convert current requests to common units
        current_cpu_request=$(convert_cpu_to_millicores "$current_cpu_request")
        current_memory_request=$(convert_memory_to_mib "$current_memory_request")

        # Fetch corresponding VPA target values
        local vpa_cpu_target=$(echo "$vpa_recommendations" | jq -r --arg container "$container" 'select(.container == $container) | .targetCpu')
        local vpa_memory_target=$(echo "$vpa_recommendations" | jq -r --arg container "$container" 'select(.container == $container) | .targetMemory')

        vpa_cpu_target=$(convert_cpu_to_millicores "$vpa_cpu_target")
        vpa_memory_target=$(convert_memory_to_mib "$vpa_memory_target")

        # Generate CPU recommendation
        if [ $((100 * (current_cpu_request - vpa_cpu_target) / vpa_cpu_target)) -gt $threshold ] || [ $((100 * (current_cpu_request - vpa_cpu_target) / vpa_cpu_target)) -lt -$threshold ]; then
            local rounded_cpu_target=$(round_up "$vpa_cpu_target" 10) # Round to nearest 10 millicores
            echo "Recommendation for $container in $object_type $object_name: Adjust CPU request from $current_cpu_request to $rounded_cpu_target millicores"
            recommendation="{\"remediation_type\":\"resource_request_update\",\"vpa_name\":\"$vpa_name\",\"resource\":\"cpu\", \"current_value\":\"$current_cpu_request\",\"suggested_value\":\"$rounded_cpu_target\",\"object_type\": \"$object_type\",\"object_name\": \"$object_name\", \"container\": \"$container\", \"severity\": \"4\", \"next_step\": \"Adjust pod resources to match VPA recommendation in \`$NAMESPACE\`\nAdjust CPU request from $current_cpu_request to $rounded_cpu_target millicores\"}"
            # Concatenate recommendation to the string
            if [ -n "$recommendation" ]; then
                if [ -z "$recommendations" ]; then
                    recommendations="$recommendation"
                else
                    recommendations="$recommendations, $recommendation"
                fi
            fi
        fi

        # Generate Memory recommendation
        if [ $((100 * (current_memory_request - vpa_memory_target) / vpa_memory_target)) -gt $threshold ] || [ $((100 * (current_memory_request - vpa_memory_target) / vpa_memory_target)) -lt -$threshold ]; then
            local rounded_memory_target=$(round_up "$vpa_memory_target" 10) # Round to nearest 10 Mi
            echo "Recommendation for $container in $object_type $object_name: Adjust Memory request from $current_memory_request to $rounded_memory_target Mi"
            recommendation="{\"remediation_type\":\"resource_request_update\",\"vpa_name\":\"$vpa_name\",\"resource\":\"memory\", \"current_value\":\"$current_memory_request\",\"suggested_value\":\"$rounded_memory_target\",\"object_type\": \"$object_type\",\"object_name\": \"$object_name\", \"container\": \"$container\", \"severity\": \"4\", \"next_step\": \"Adjust pod resources to match VPA recommendation in \`$NAMESPACE\`\nAdjust Memory request from $current_memory_request to $rounded_memory_target Mi\"}"
            # Concatenate recommendation to the string
            if [ -n "$recommendation" ]; then
                if [ -z "$recommendations" ]; then
                    recommendations="$recommendation"
                else
                    recommendations="$recommendations, $recommendation"
                fi
            fi
        fi

    done < <(echo "$current_requests" | jq -c .)
}



# Fetching VPA details
vpa_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get vpa -n ${NAMESPACE} --context ${CONTEXT} -o json)

# Processing the VPA JSON
echo "VPA Recommendations for Namespace: ${NAMESPACE} for Context: ${CONTEXT}"
echo "==========================================="

# Parsing VPA JSON
while IFS= read -r vpa_item; do
    vpa_name=$(echo "$vpa_item" | jq -r '.metadata.name')
    analyze_vpa "$vpa_name" "$NAMESPACE" "$vpa_item"
done < <(echo "$vpa_json" | jq -c '.items[]')



# Outputting recommendations as JSON
if [ -n "$recommendations" ]; then
    echo "Recommended Next Steps:"
    echo "[$recommendations]" | jq .
else
    echo "No recommendations."
fi