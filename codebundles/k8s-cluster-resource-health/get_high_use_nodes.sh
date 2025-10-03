#!/bin/bash

# Define Kubernetes binary and context with dynamic defaults
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

KUBERNETES_DISTRIBUTION_BINARY="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}" # Default to 'kubectl' if not set in the environment
DEFAULT_CONTEXT=$(${KUBERNETES_DISTRIBUTION_BINARY} config current-context)
CONTEXT="${CONTEXT:-$DEFAULT_CONTEXT}" # Use environment variable or the current context from kubectl



process_nodes_and_usage() {
    # Get Node Details including allocatable resources
    nodes=$(${KUBERNETES_DISTRIBUTION_BINARY} get nodes --context ${CONTEXT} -o json | jq '[.items[] | {
        name: .metadata.name,
        cpu_allocatable: (.status.allocatable.cpu | rtrimstr("m") | tonumber),
        memory_allocatable: (.status.allocatable.memory | gsub("Ki"; "") | tonumber / 1024)
    }]')

    # Fetch node usage details
    usage=$(${KUBERNETES_DISTRIBUTION_BINARY} top nodes --context ${CONTEXT} | awk 'BEGIN { printf "[" } NR>1 { printf "%s{\"name\":\"%s\",\"cpu_usage\":\"%s\",\"memory_usage\":\"%s\"}", (NR>2 ? "," : ""), $1, ($2 == "<unknown>" ? "0" : $2), ($4 == "<unknown>" ? "0" : $4) } END { printf "]" }' | jq '.')

    # Combine and process the data
    jq -n --argjson nodes "$nodes" --argjson usage "$usage" '{
        nodes: $nodes | map({name: .name, cpu_allocatable: .cpu_allocatable, memory_allocatable: .memory_allocatable}),
        usage: $usage | map({name: .name, cpu_usage: (.cpu_usage | rtrimstr("m") | tonumber // 0), memory_usage: (.memory_usage | rtrimstr("Mi") | tonumber // 0)})
    } | .nodes as $nodes | .usage as $usage | 
    $nodes | map(
        . as $node | 
        $usage[] | 
        select(.name == $node.name) | 
        {
            name: .name, 
            cpu_utilization_percentage: (.cpu_usage / $node.cpu_allocatable * 100),
            memory_utilization_percentage: (.memory_usage / $node.memory_allocatable * 100)
        }
    ) | map(select(.cpu_utilization_percentage >= 90 or .memory_utilization_percentage >= 90))'
}

process_nodes_and_usage > high_use_nodes.json

cat high_use_nodes.json