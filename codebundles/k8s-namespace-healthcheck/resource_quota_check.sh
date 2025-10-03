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

# Function to calculate and display resource usage status with recommendations
check_usage() {
    local quota_name=$1
    local resource=$2
    local used=$3
    local hard=$4

    # Convert memory and CPU to a common unit (Mi and millicores respectively)
    if [[ $resource == *memory* ]]; then
        used=$(convert_memory_to_mib $used)
        hard=$(convert_memory_to_mib $hard)
    elif [[ $resource == *cpu* ]]; then
        used=$(convert_cpu_to_millicores $used)
        hard=$(convert_cpu_to_millicores $hard)
    fi

    # Calculating percentage
    local percentage=0
    if [ $hard -ne 0 ]; then
        percentage=$(( 100 * used / hard ))
    fi

    # Generate recommendation based on usage
    local recommendation=""
    local increase_percentage=0
    local increased_value=0
    if [ $percentage -ge 100 ]; then
        if [ $used -gt $hard ]; then
            # If usage is over 100%, match the current usage
            echo "$resource: OVER LIMIT ($percentage%) - Adjust resource quota to match current usage with some headroom for $resource in $NAMESPACE"
            increase_percentage="${CRITICAL_INCREASE_LEVEL:-40}"
            increased_value=$(( used * increase_percentage / 100 ))
            suggested_value=$(( increased_value + used ))
        else
            echo "$resource: AT LIMIT ($percentage%) - Immediately increase the resource quota for $resource in $NAMESPACE"
            increase_percentage="${CRITICAL_INCREASE_LEVEL:-40}"
            increased_value=$(( hard * increase_percentage / 100 ))
            suggested_value=$(( increased_value + hard ))
        fi
        recommendation="{\"remediation_type\":\"resourcequota_update\",\"increase_percentage\":\"$increase_percentage\",\"limit_type\":\"hard\",\"current_value\":\"$hard\",\"suggested_value\":\"$suggested_value\",\"quota_name\": \"$quota_name\", \"resource\": \"$resource\", \"usage\": \"at or above 100%\", \"severity\": \"1\", \"next_step\": \"Increase the resource quota for $resource in \`$NAMESPACE\`\"}"
    elif [ $percentage -ge 90 ]; then
        echo "$resource: WARNING ($percentage%) - Consider increasing the resource quota for $resource in $NAMESPACE"
        increase_percentage="${WARNING_INCREASE_LEVEL:-25}"
        increased_value=$(( hard * increase_percentage / 100 ))
        suggested_value=$(( increased_value + hard ))
        recommendation="{\"remediation_type\":\"resourcequota_update\",\"increase_percentage\":\"$increase_percentage\",\"limit_type\":\"hard\",\"current_value\":\"$hard\",\"suggested_value\":\"$suggested_value\",\"quota_name\": \"$quota_name\", \"resource\": \"$resource\", \"usage\": \"between 90-99%\", \"severity\": \"2\", \"next_step\": \"Consider increasing the resource quota for $resource in \`$NAMESPACE\`\"}"
    elif [ $percentage -ge 80 ]; then
        echo "$resource: INFO ($percentage%) - Monitor the resource quota for $resource in $NAMESPACE"
        increase_percentage="${INFO_INCREASE_LEVEL:-10}"
        increased_value=$(( hard * increase_percentage / 100 ))
        suggested_value=$(( increased_value + hard ))
        recommendation="{\"remediation_type\":\"resourcequota_update\",\"increase_percentage\":\"$increase_percentage\",\"limit_type\":\"hard\",\"current_value\":\"$hard\",\"suggested_value\":\"$suggested_value\",\"quota_name\": \"$quota_name\", \"resource\": \"$resource\", \"usage\": \"between 80-90%\", \"severity\": \"3\", \"next_step\": \"Monitor the resource quota for $resource in \`$NAMESPACE\`\"}"
    else
        echo "$resource: OK ($percentage%)"
    fi

    # Concatenate recommendation to the string
    if [ -n "$recommendation" ]; then
        if [ -z "$recommendations" ]; then
            recommendations="$recommendation"
        else
            recommendations="$recommendations, $recommendation"
        fi
    fi
}

# Fetching resource quota details
quota_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get quota -n "$NAMESPACE" --context "$CONTEXT" -o json)

# Processing the quota JSON
echo "Resource Quota and Usage for Namespace: $NAMESPACE in Context: $CONTEXT"
echo "==========================================="

# Parsing quota JSON
while IFS= read -r item; do
    quota_name=$(echo "$item" | jq -r '.metadata.name')
    echo "Quota: $quota_name"

    # Create temporary files
    hard_file=$(mktemp)
    used_file=$(mktemp)

    echo "$item" | jq -r '.status.hard | to_entries | .[] | "\(.key) \(.value)"' > "$hard_file"
    echo "$item" | jq -r '.status.used | to_entries | .[] | "\(.key) \(.value)"' > "$used_file"

    # Process 'hard' limits and 'used' resources
    while read -r key value; do
        hard=$(grep "^$key " "$hard_file" | awk '{print $2}')
        used=$(grep "^$key " "$used_file" | awk '{print $2}')
        check_usage "$quota_name" "$key" "${used:-0}" "$hard"
    done < "$hard_file"

    echo "-----------------------------------"

    # Clean up temporary files
    rm "$hard_file" "$used_file"
done < <(echo "$quota_json" | jq -c '.items[]')

# Outputting recommendations as JSON
if [ -n "$recommendations" ]; then
    echo "Recommended Next Steps:"
    echo "[$recommendations]" | jq .
else
    echo "No recommendations."
fi