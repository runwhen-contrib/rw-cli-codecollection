#!/bin/bash

#set -euo pipefail

# Constants
ERROR_JSON="controlplane_error_patterns.json"
ISSUE_FILE="${OUTPUT_DIR}/istio_controlplane_issues.json"
REPORT_FILE="${OUTPUT_DIR}/istio_controlplane_report.json"
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

# Load namespaces
ISTIO_NAMESPACES=$(${KUBERNETES_DISTRIBUTION_BINARY} get namespaces --context="${CONTEXT}" --no-headers -o custom-columns=":metadata.name" | grep istio)
ISTIO_COMPONENTS=("istiod" "istio-ingressgateway" "istio-egressgateway")

# Check for error pattern file
if [[ ! -f "$ERROR_JSON" ]]; then
    echo "❌ Error: JSON file '$ERROR_JSON' not found!"
    exit 1
fi

WARNINGS=($(jq -r '.warnings[]' "$ERROR_JSON"))
ERRORS=($(jq -r '.errors[]' "$ERROR_JSON"))

echo "🔍 Checking Istio Control Plane Logs for Exact Matches..."
echo "-----------------------------------------------------------------------------------------------------------"

for COMPONENT in "${ISTIO_COMPONENTS[@]}"; do
    for NS in $ISTIO_NAMESPACES; do
        PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NS --context="${CONTEXT}" -l app=$COMPONENT --no-headers -o custom-columns=":metadata.name")

        for POD in $PODS; do
            echo "📜 Checking logs for $POD in namespace $NS..."

            LOGS=$(${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -n $NS --context="${CONTEXT}" --since=$LOG_DURATION 2>/dev/null)

            for WARNING in "${WARNINGS[@]}"; do
                if echo "$LOGS" | grep -Fx "$WARNING" &>/dev/null; then
                    echo "⚠️ Warning found: '$WARNING' in $POD ($NS)"
                    ISSUES+=("$(jq -n \
                        --arg severity "medium" \
                        --arg expected "No critical logs in control plane" \
                        --arg actual "$WARNING in $POD ($NS)" \
                        --arg title "Control plane log issue: warning" \
                        --arg reproduce_hint "${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -n $NS --context=${CONTEXT} --since=$LOG_DURATION | grep \"$WARNING\"" \
                        --arg next_steps "Investigate the log entry in pod logs" \
                        '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')")
                fi
            done

            for ERROR in "${ERRORS[@]}"; do
                if echo "$LOGS" | grep -Fx "$ERROR" &>/dev/null; then
                    echo "🚨 Error found: '$ERROR' in $POD ($NS)"
                    ISSUES+=("$(jq -n \
                        --arg severity "high" \
                        --arg expected "No critical logs in control plane" \
                        --arg actual "$ERROR in $POD ($NS)" \
                        --arg title "Control plane log issue: error" \
                        --arg reproduce_hint "${KUBERNETES_DISTRIBUTION_BINARY} logs $POD -n $NS --context=${CONTEXT} --since=$LOG_DURATION | grep \"$ERROR\"" \
                        --arg next_steps "Investigate the log entry in pod logs" \
                        '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')")
                fi
            done
        done
    done
done

echo "-----------------------------------------------------------------------------------------------------------"

if [ ${#ISSUES[@]} -eq 0 ]; then
    echo "✅ No warnings or errors detected in Istio logs."
else
    echo "⚠️  Some warnings/errors were found in the logs. Please investigate further."

    jq -s '.' <<< "${ISSUES[@]}" > "$ISSUE_FILE"
    echo "✅ Issues written to: $ISSUE_FILE"
fi

# Optionally, write a minimal report
jq -n --arg time "$(date -Iseconds)" --arg status "completed" \
    '{"check": "control-plane-logs", "status": $status, "time": $time}' > "$REPORT_FILE"
