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

    local vpa_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get vpa "$vpa_name" -n "$namespace" -o json)
    echo "$vpa_json" | jq -r '.spec.targetRef | "\(.kind) \(.name)"'
}

# Function to get current CPU and Memory requests for the target object
get_current_requests() {
    local object_type=$1
    local object_name=$2
    local namespace=$3

    if [[ "$object_type" == "Deployment" ]]; then
        local target_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get "$object_type" "$object_name" -n "$namespace" -o json)
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
            recommendation="{\"remediation_type\":\"resource_request_update\",\"vpa_name\":\"$vpa_name\",\"resource\":\"cpu\", \"current_value\":\"$current_cpu_request\",\"suggested_value\":\"$rounded_cpu_target\",\"object_type\": \"$object_type\",\"object_name\": \"$object_name\", \"container\": \"$container\", \"severity\": \"4\"}"
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
            recommendation="{\"remediation_type\":\"resource_request_update\",\"vpa_name\":\"$vpa_name\",\"resource\":\"memory\", \"current_value\":\"$current_memory_request\",\"suggested_value\":\"$rounded_memory_target\",\"object_type\": \"$object_type\",\"object_name\": \"$object_name\", \"container\": \"$container\", \"severity\": \"4\"}"
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