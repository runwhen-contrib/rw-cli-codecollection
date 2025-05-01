#!/bin/bash

#set -euo pipefail

# Constants
ERROR_JSON="${CURDIR}/proxy_error_patterns.json"
ISSUES_FILE="${OUTPUT_DIR}/istio_proxy_issues.json"
REPORT_FILE="${OUTPUT_DIR}/istio_proxy_report.json"
LOG_DURATION="1h" # Fetch logs from the last 1 hour
declare -a ISSUES=()

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
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers &> /dev/null; then
        echo "=== Available Contexts ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts
        echo "Error: Unable to get cluster contexts"
        exit 1
    fi

    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" &> /dev/null; then
        echo "Error: Unable to connect to the cluster. Please check your kubeconfig and cluster status."
        exit 1
    fi

    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" &> /dev/null; then
        echo "Error: Unable to reach Kubernetes API server"
        exit 1
    fi
}

# Function to check JSON parsing error
function check_jq_error() {
    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse JSON output"
        exit 1
    fi
}

# Verify required commands exist
check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq

# Check cluster connectivity
check_cluster_connection

# Load error patterns
if [[ ! -f "$ERROR_JSON" ]]; then
    echo "❌ Error: JSON file '$ERROR_JSON' not found!"
    exit 1
fi

# WARNINGS=($(jq -r '.warnings[]' "$ERROR_JSON"))
# ERRORS=($(jq -r '.errors[]' "$ERROR_JSON"))

# Fetch and filter namespaces
NAMESPACES_JSON=$("${KUBERNETES_DISTRIBUTION_BINARY}" get namespaces --context="${CONTEXT}" -o json)
if [ $? -ne 0 ]; then
    echo "Error: Failed to get namespaces. Please check your permissions and cluster status."
    exit 1
fi

# Convert comma-separated EXCLUDED_NAMESPACES to jq array format
EXCLUDED_NS_ARRAY=$(echo "${EXCLUDED_NAMESPACES}" | jq -R 'split(",")')

# Filter namespaces excluding the specified ones
FILTERED_NAMESPACES=$(echo "$NAMESPACES_JSON" | jq -r --argjson excluded "${EXCLUDED_NS_ARRAY}" \
    '.items[].metadata.name | select(. as $ns | ($excluded | index($ns) | not))')
check_jq_error

if [ -z "$FILTERED_NAMESPACES" ]; then
    echo "Error: No namespaces found (excluding: ${EXCLUDED_NAMESPACES})"
    exit 1
fi

echo "🔍 Checking istio-proxy logs across namespaces..."
echo "-----------------------------------------------------------------------------------------------------------"

for NS in $FILTERED_NAMESPACES; do
    PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NS" --context="${CONTEXT}" --no-headers -o custom-columns=":metadata.name")

    for POD in $PODS; do
        # Check if the pod has istio-proxy container
        CONTAINERS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$POD" -n "$NS" --context="${CONTEXT}" -o jsonpath='{.spec.containers[*].name}')

        if [[ "$CONTAINERS" == *"istio-proxy"* ]]; then
            echo "📜 Checking istio-proxy logs for $POD in namespace $NS..."

            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs "$POD" -c istio-proxy -n "$NS" --context="${CONTEXT}" --since="$LOG_DURATION" 2>/dev/null)

            while IFS= read -r WARNING; do
                if echo "$LOGS" | grep -Fq "$WARNING"; then
                    echo "Warning found: '$WARNING' in $POD ($NS)"
                    ISSUES+=("$(jq -n \
                        --arg severity "3" \
                        --arg expected "No warnings in istio-proxy logs for pod $POD in namespace $NS" \
                        --arg actual "Warning \"$WARNING\" for pod $POD in namespace $NS" \
                        --arg title "istio-proxy has a warning for pod $POD in namespace $NS" \
                        --arg reproduce_hint "${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c istio-proxy -n $NS --context=${CONTEXT} --since=$LOG_DURATION | grep \"$WARNING\"" \
                        --arg next_steps "Check mesh configuration and app behavior" \
                        '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')")
                fi
            done < <(jq -r '.warnings[]' "$ERROR_JSON")
            
            while IFS= read -r ERROR; do
                if echo "$LOGS" | grep -Fq "$ERROR"; then
                    echo "Error found: '$ERROR' in $POD ($NS)"
                    ISSUES+=("$(jq -n \
                        --arg severity "2" \
                        --arg expected "No errors in istio-proxy logs for pod $POD in namespace $NS" \
                        --arg actual "Error \"$ERROR\" for pod $POD in namespace ($NS)" \
                        --arg title "istio-proxy has a error for pod $POD in namespace $NS" \
                        --arg reproduce_hint "${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -c istio-proxy -n $NS --context=${CONTEXT} --since=$LOG_DURATION | grep \"$ERROR\"" \
                        --arg next_steps "Check for misconfigurations, service availability, or mTLS issues" \
                        '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')")
                fi
            done < <(jq -r '.errors[]' "$ERROR_JSON")
        fi
    done
done

echo "-----------------------------------------------------------------------------------------------------------"

if [ ${#ISSUES[@]} -eq 0 ]; then
    echo "✅ No warnings or errors detected in Istio proxy logs."
else
    echo "⚠️  Some warnings/errors were found in the logs. Please investigate further."

    jq -s '.' <<< "${ISSUES[@]}" > "$ISSUES_FILE"
    echo "✅ Issues written to: $ISSUES_FILE"
fi

# Write final report
jq -n --arg time "$(date -Iseconds)" --arg status "completed" \
    '{"check": "control-plane-logs", "status": $status, "time": $time}' > "$REPORT_FILE"
