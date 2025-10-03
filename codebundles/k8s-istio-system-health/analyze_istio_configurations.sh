#!/bin/bash

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

REPORT_FILE="report_istio_analyze.txt"
ISSUES_FILE="issues_istio_analyze.json"

# Prepare output files
echo "" > "$REPORT_FILE"
echo "[]" > "$ISSUES_FILE"

# Check dependencies
function check_command_exists() {
    if ! command -v "$1" &> /dev/null; then        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

        # Extract timestamp from log context


        log_timestamp=$(extract_log_timestamp "$0")


        echo "Error: $1 not found (detected at $log_timestamp)"
        exit 1
    fi
}

check_command_exists jq
check_command_exists istioctl
check_command_exists "$KUBERNETES_DISTRIBUTION_BINARY"

# Check cluster connection
function check_cluster_connection() {
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" >/dev/null 2>&1; then        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

        # Extract timestamp from log context


        log_timestamp=$(extract_log_timestamp "$0")


        echo "Error: Unable to connect to cluster context '${CONTEXT}' (detected at $log_timestamp)"
        exit 1
    fi
}

check_cluster_connection

# Collect namespaces
ALL_NAMESPACES=$("${KUBERNETES_DISTRIBUTION_BINARY}" get ns --context="${CONTEXT}" -o jsonpath="{.items[*].metadata.name}")

ISSUES=()

for NS in $ALL_NAMESPACES; do
    if [[ " ${EXCLUDED_NAMESPACES[*]} " =~ " ${NS} " ]]; then
        continue
    fi

    echo -e "\nNamespace: $NS" >> "$REPORT_FILE"

    OUTPUT=$(istioctl analyze -n "$NS" --context="${CONTEXT}" -o json 2>/dev/null || echo "[]")

    COUNT=$(echo "$OUTPUT" | jq 'length')
    if [ "$COUNT" -eq 0 ]; then
        echo "✅ No issues found in namespace $NS" >> "$REPORT_FILE"
        continue
    fi

    for ((i=0; i<COUNT; i++)); do
        level=$(echo "$OUTPUT" | jq -r ".[$i].level")
        code=$(echo "$OUTPUT" | jq -r ".[$i].code")
        raw_message=$(echo "$OUTPUT" | jq -r ".[$i].message")
        message=$(printf '%s' "$raw_message" | sed 's/"/\\"/g')
        resource=$(echo "$OUTPUT" | jq -r ".[$i].resource.name // \"unknown\"")
        resource_name=$(echo "$OUTPUT" | jq -r ".[$i].resource.name // \"unknown\"")
        resource_ns=$(echo  "$OUTPUT" | jq -r ".[$i].resource.namespace // \"$NS\"")

        if [[ "$level" == "Info" ]]; then
            line="[$level] $code - $raw_message"
            echo "$line" >> "$REPORT_FILE"
        fi

        level_lower=$(echo "$level" | tr '[:upper:]' '[:lower:]')
        if [[ "$level_lower" == "warning" || "$level_lower" == "error" ]]; then
            severity_code=0
            if [[ "$level_lower" == "error" ]]; then
                severity_code=1
            elif [[ "$level_lower" == "warning" ]]; then
                severity_code=2
            fi

            ISSUES+=("{
            \"severity\": ${severity_code},
            \"namespace\": \"${resource_ns}\",
            \"resource\": \"${resource_name}\",
            \"expected\": \"No ${level_lower}s from istioctl analyze for resource ${resource_name}\",
            \"actual\": \"${message}\",
            \"title\": \"Istio \`${level}\` in namespace \`${resource_ns}\`: \`${code}\`\",
            \"reproduce_hint\": \"istioctl analyze -n ${resource_ns}\",
            \"next_steps\": \"Review \`${resource_name}\` in namespace \`${resource_ns}\` for Istio mis-configuration.\"
            }")
        fi
    done
done

# Write issues file
if [ ${#ISSUES[@]} -gt 0 ]; then
    printf "%s\n" "${ISSUES[@]}" | jq -s '.' > "$ISSUES_FILE"
else
    echo "✅ No issues detected. Skipping issue file creation."
fi
