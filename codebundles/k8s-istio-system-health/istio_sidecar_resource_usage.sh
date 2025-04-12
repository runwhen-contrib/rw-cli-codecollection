#!/bin/bash

# Threshold
THRESHOLD=80

REPORT_FILE="${OUTPUT_DIR}/istio_sidecar_resource_usage_report.txt"
ISSUES_FILE="${OUTPUT_DIR}/issues_istio_resource_usage.json"

# Prepare files
echo "" > "$REPORT_FILE"
echo "[]" > "$ISSUES_FILE"

# Function to check if a command exists
function check_command_exists() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 could not be found"
        exit 1
    fi
}

# Function to check cluster connectivity
function check_cluster_connection() {
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers >/dev/null 2>&1; then
        echo "Error: Unable to get cluster contexts"
        "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts
        exit 1
    fi

    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" >/dev/null 2>&1; then
        echo "Error: Unable to connect to the cluster"
        "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}"
        exit 1
    fi

    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" >/dev/null 2>&1; then
        echo "Error: Unable to reach Kubernetes API server"
        exit 1
    fi
}

check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq
check_cluster_connection

# Arrays to collect issues
ISSUES=()
NO_LIMITS_PODS=()
ZERO_USAGE_PODS=()
HIGH_USAGE_PODS=()



# Start the report
{
    printf "%-15s %-40s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
        "Namespace" "Pod" "CPU_Limits(m)" "CPU_Usage(m)" "CPU_Usage(%)" "Mem_Limits(Mi)" "Mem_Usage(Mi)" "Mem_Usage(%)"
    echo "-----------------------------------------------------------------------------------------------------------------------------------------------------"
} > "$REPORT_FILE"

NAMESPACES=$(${KUBERNETES_DISTRIBUTION_BINARY} get namespaces --context="${CONTEXT}" --no-headers -o custom-columns=":metadata.name")

for NS in $NAMESPACES; do
    PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NS --context="${CONTEXT}" -o jsonpath="{.items[*].metadata.name}")

    for POD in $PODS; do
        CONTAINER_NAMES=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n $NS --context="${CONTEXT}" -o jsonpath="{.spec.containers[*].name}")

        if echo "$CONTAINER_NAMES" | grep -q "istio-proxy"; then
            CPU_LIMITS_RAW=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n $NS --context="${CONTEXT}" -o jsonpath="{.spec.containers[?(@.name=='istio-proxy')].resources.limits.cpu}")
            CPU_LIMITS=$(echo $CPU_LIMITS_RAW | sed 's/m//')
            if [[ "$CPU_LIMITS_RAW" =~ ^[0-9]+$ ]]; then
                CPU_LIMITS=$((CPU_LIMITS * 1000))
            fi

            MEM_LIMITS_RAW=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $POD -n $NS --context="${CONTEXT}" -o jsonpath="{.spec.containers[?(@.name=='istio-proxy')].resources.limits.memory}")
            if [[ $MEM_LIMITS_RAW == *Gi ]]; then
                MEM_LIMITS=$(( $(echo $MEM_LIMITS_RAW | sed 's/Gi//') * 1024 ))
            else
                MEM_LIMITS=$(echo $MEM_LIMITS_RAW | sed 's/Mi//')
            fi

            CPU_USAGE=$(${KUBERNETES_DISTRIBUTION_BINARY} top pod $POD -n $NS --context="${CONTEXT}" --containers 2>/dev/null | awk '$2 == "istio-proxy" {print $3}' | sed 's/m//')
            MEM_USAGE_RAW=$(${KUBERNETES_DISTRIBUTION_BINARY} top pod $POD -n $NS --context="${CONTEXT}" --containers 2>/dev/null | awk '$2 == "istio-proxy" {print $4}')

            if [[ $MEM_USAGE_RAW == *Gi ]]; then
                MEM_USAGE=$(( $(echo $MEM_USAGE_RAW | sed 's/Gi//') * 1024 ))
            else
                MEM_USAGE=$(echo $MEM_USAGE_RAW | sed 's/Mi//' )
            fi

            if [[ -z "$CPU_LIMITS" || -z "$MEM_LIMITS" ]]; then
                NO_LIMITS_PODS+=("$NS $POD")
                ISSUES+=("{
                    \"severity\": \"1\",
                    \"expected\": \"All istio-proxy containers should have resource limits defined\",
                    \"actual\": \"Missing resource limits for pod $POD in namespace $NS\",
                    \"title\": \"Missing resource limits for pod $POD in namespace $NS\",
                    \"reproduce_hint\": \"kubectl get pod $POD -n $NS -o jsonpath='{.spec.containers[?(@.name==\"istio-proxy\")].resources}'\",
                    \"next_steps\": \"Update deployment spec to include resource limits for the istio-proxy container\"
                }")
                continue
            fi

            if [[ -z "$CPU_USAGE" || "$CPU_USAGE" == "0" || -z "$MEM_USAGE" || "$MEM_USAGE" == "0" ]]; then
                ZERO_USAGE_PODS+=("$NS $POD")
                ISSUES+=("{
                    \"severity\": \"2\",
                    \"expected\": \"istio-proxy should be consuming resources under normal operation\",
                    \"actual\": \"Zero or unavailable usage stats for pod $POD in namespace $NS\",
                    \"title\": \"Zero or Missing Resource Usage for pod $POD in namespace $NS\",
                    \"reproduce_hint\": \"kubectl top pod $POD -n $NS --containers | grep istio-proxy\",
                    \"next_steps\": \"Check pod status and connectivity. It may be crashing, pending, or unscheduled.\"
                }")
                continue
            fi

            CPU_PERCENTAGE=$(awk "BEGIN {printf \"%.2f\", ($CPU_USAGE * 100) / $CPU_LIMITS}")
            MEM_PERCENTAGE=$(awk "BEGIN {printf \"%.2f\", ($MEM_USAGE * 100) / $MEM_LIMITS}")

            # Track high usage
            if (( $(echo "$CPU_PERCENTAGE > $THRESHOLD" | bc -l) )) || (( $(echo "$MEM_PERCENTAGE > $THRESHOLD" | bc -l) )); then
                HIGH_USAGE_PODS+=("$NS $POD")
                ISSUES+=("{
                    \"severity\": \"3\",
                    \"expected\": \"Resource usage should remain below ${THRESHOLD}%%\",
                    \"actual\": \"Pod $POD in namespace $NS has CPU=${CPU_PERCENTAGE}%%, Memory=${MEM_PERCENTAGE}%%\",
                    \"title\": \"High istio-proxy resource usage for pod $POD in namespace $NS\",
                    \"reproduce_hint\": \"kubectl top pod $POD -n $NS --containers | grep istio-proxy\",
                    \"next_steps\": \"Investigate the workload for memory leaks or CPU throttling.\"
                }")
            fi

            printf "%-15s %-40s %-15s %-15s %-15s %-15s %-15s %-15s\n" \
                "$NS" "$POD" "$CPU_LIMITS" "$CPU_USAGE" "${CPU_PERCENTAGE}%" "$MEM_LIMITS" "$MEM_USAGE" "${MEM_PERCENTAGE}%" >> "$REPORT_FILE"
        fi
    done
done

# Append additional tables
{
    echo ""
    echo "Pods Without Limits:"
    echo "----------------------------------------------"
    if [ ${#NO_LIMITS_PODS[@]} -eq 0 ]; then
        echo "There are no pods without limits set."
    else
        printf "%-15s %-40s\n" "Namespace" "Pod"
        for ENTRY in "${NO_LIMITS_PODS[@]}"; do
            printf "%-15s %-40s\n" $ENTRY
        done
    fi

    echo ""
    echo "Pods With Zero or Missing Usage:"
    echo "----------------------------------------------"
    if [ ${#ZERO_USAGE_PODS[@]} -eq 0 ]; then
        echo "There are no pods with zero or missing usage."
    else
        printf "%-15s %-40s\n" "Namespace" "Pod"
        for ENTRY in "${ZERO_USAGE_PODS[@]}"; do
            printf "%-15s %-40s\n" $ENTRY
        done
    fi

    echo ""
    echo "Pods With High Resource Usage (> ${THRESHOLD}%):"
    echo "--------------------------------------------------------------"
    if [ ${#HIGH_USAGE_PODS[@]} -eq 0 ]; then
        echo "There are no pods exceeding ${THRESHOLD}% usage."
    else
        printf "%-15s %-40s\n" "Namespace" "Pod"
        for ENTRY in "${HIGH_USAGE_PODS[@]}"; do
            printf "%-15s %-40s\n" $ENTRY
        done
    fi
} >> "$REPORT_FILE"

# Write JSON issues
if [ ${#ISSUES[@]} -gt 0 ]; then
    printf "%s\n" "${ISSUES[@]}" | jq -s '.' > "$ISSUES_FILE"
    #echo "${ISSUES[@]}"
else
    echo "No issues detected. Skipping issue file creation."
fi