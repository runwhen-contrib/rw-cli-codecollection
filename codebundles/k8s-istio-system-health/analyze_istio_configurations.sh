#!/bin/bash

REPORT_FILE="report_istio_analyze.txt"
ISSUES_FILE="issues_istio_analyze.json"

# Prepare output files
echo "" > "$REPORT_FILE"
echo "[]" > "$ISSUES_FILE"

# Check dependencies
function check_command_exists() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 not found"
        exit 1
    fi
}

check_command_exists jq
check_command_exists istioctl
check_command_exists "$KUBERNETES_DISTRIBUTION_BINARY"

# Check cluster connection
function check_cluster_connection() {
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" >/dev/null 2>&1; then
        echo "Error: Unable to connect to cluster context '${CONTEXT}'"
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
            \"title\": \"Istio ${level} in namespace ${resource_ns}: ${code}\",
            \"reproduce_hint\": \"istioctl analyze -n ${resource_ns}\",
            \"next_steps\": \"Review ${resource_name} in ${resource_ns} for mis-configuration.\"
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
