#!/bin/bash

REPORT_FILE="${OUTPUT_DIR}/istio_installation_report.txt"
ISSUES_FILE="${OUTPUT_DIR}/istio_installation_issues.json"
LOG_TAIL_COUNT=50  # ⬅️ Set the number of log lines to tail here

# Prepare files
echo "" > "$REPORT_FILE"
echo "[]" > "$ISSUES_FILE"

# Standard Validation Functions
function check_command_exists() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 could not be found"
        exit 1
    fi
}

function check_cluster_connection() {
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers &>/dev/null; then
        echo "=== Available Contexts ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts
        echo "Error: Unable to get cluster contexts"
        exit 1
    fi
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" &>/dev/null; then
        echo "=== Cluster Info ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}"
        echo "Error: Unable to connect to the cluster"
        exit 1
    fi
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" &>/dev/null; then
        echo "Error: Unable to reach Kubernetes API server"
        exit 1
    fi
}

function check_jq_error() {
    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse JSON output"
        exit 1
    fi
}

check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq
check_cluster_connection

# Variables
ISTIO_COMPONENTS=("istiod" "istio-ingressgateway" "istio-egressgateway")
ISTIO_NAMESPACES=$(${KUBERNETES_DISTRIBUTION_BINARY} get namespaces --context="${CONTEXT}" --no-headers -o custom-columns=":metadata.name" | grep istio)
ISSUES=()

echo "🔍 Checking Istio Control Plane Components..."
echo "-----------------------------------------------------------------------------------------------------------"
printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" "Component" "Namespace" "Status" "Pods" "Restarts" "Warnings/Errors"
echo "-----------------------------------------------------------------------------------------------------------"

for COMPONENT in "${ISTIO_COMPONENTS[@]}"; do
    COMPONENT_FOUND=false

    for NS in $ISTIO_NAMESPACES; do
        PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NS" -l app=$COMPONENT --no-headers -o custom-columns=":metadata.name" --context="${CONTEXT}")

        if [[ -n "$PODS" ]]; then
            COMPONENT_FOUND=true
            TOTAL_PODS=0
            RUNNING_PODS=0
            TOTAL_RESTARTS=0
            TOTAL_WARNINGS=0

            for POD in $PODS; do
                TOTAL_PODS=$((TOTAL_PODS + 1))

                POD_STATUS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$POD" -n "$NS" -o jsonpath="{.status.phase}" --context="${CONTEXT}")
                if [[ "$POD_STATUS" == "Running" ]]; then
                    RUNNING_PODS=$((RUNNING_PODS + 1))
                fi

                RESTARTS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$POD" -n "$NS" -o jsonpath="{.status.containerStatuses[*].restartCount}" --context="${CONTEXT}")
                RESTARTS_SUM=0
                for COUNT in $RESTARTS; do
                    RESTARTS_SUM=$((RESTARTS_SUM + COUNT))
                done
                TOTAL_RESTARTS=$((TOTAL_RESTARTS + RESTARTS_SUM))

                WARNINGS=$(${KUBERNETES_DISTRIBUTION_BINARY} get events -n "$NS" --field-selector involvedObject.name="$POD",type!=Normal --no-headers --context="${CONTEXT}" 2>/dev/null | wc -l)
                TOTAL_WARNINGS=$((TOTAL_WARNINGS + WARNINGS))

                if [[ "$WARNINGS" -gt 0 ]]; then
                    EVENT_DETAILS=$(${KUBERNETES_DISTRIBUTION_BINARY} get events -n "$NS" --field-selector involvedObject.name="$POD",type!=Normal --sort-by=.metadata.creationTimestamp --context="${CONTEXT}")

                    # Get logs from all containers in the pod
                    CONTAINERS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$POD" -n "$NS" -o jsonpath="{.spec.containers[*].name}" --context="${CONTEXT}")

                    {
                        echo ""
                        echo "🔶 Pod: $POD"
                        echo "🔸 Namespace: $NS"
                        echo "🔸 Events:"
                        echo "------------------------------------------"
                        echo "$EVENT_DETAILS"
                        echo "------------------------------------------"

                        for CONTAINER in $CONTAINERS; do
                            echo ""
                            echo "🔸 Logs for container: $CONTAINER (last $LOG_TAIL_COUNT lines)"
                            echo "------------------------------------------"
                            ${KUBERNETES_DISTRIBUTION_BINARY} logs "$POD" -n "$NS" -c "$CONTAINER" --tail="$LOG_TAIL_COUNT" --context="${CONTEXT}" 2>&1
                            echo "------------------------------------------"
                        done
                    } >> "$REPORT_FILE"

                    ISSUES+=("$(jq -n \
                        --arg severity "3" \
                        --arg expected "No warning/error events for Istio controlplane pod $POD in namespace $NS" \
                        --arg actual "$EVENT_DETAILS" \
                        --arg title "Event warnings for pod $POD in namespace $NS" \
                        --arg reproduce_hint "${KUBERNETES_DISTRIBUTION_BINARY} get events -n $NS --field-selector involvedObject.name=$POD,type!=Normal" \
                        --arg next_steps "Investigate the pod and its container logs for root cause" \
                        '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')")
                fi
            done

            STATUS="RUNNING"
            if [[ $TOTAL_PODS -ne $RUNNING_PODS ]]; then
                STATUS="PARTIALLY RUNNING"
                ISSUES+=("$(jq -n \
                    --arg severity "1" \
                    --arg expected "controlplane component $COMPONENT should be running" \
                    --arg actual "$RUNNING_PODS out of $TOTAL_PODS pods running for component $COMPONENT in namespace $NS" \
                    --arg title "Component $COMPONENT is not fully running in namespace $NS" \
                    --arg reproduce_hint "${KUBERNETES_DISTRIBUTION_BINARY} get pods -n $NS -l app=$COMPONENT --context=$CONTEXT" \
                    --arg next_steps "Check the pod status and logs to identify startup issues" \
                    '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')")
            fi

            printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" "$COMPONENT" "$NS" "$STATUS" "$RUNNING_PODS/$TOTAL_PODS" "$TOTAL_RESTARTS" "$TOTAL_WARNINGS"
        fi
    done

    if [[ "$COMPONENT_FOUND" = false ]]; then
        printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" "$COMPONENT" "N/A" "NOT INSTALLED" "0/0" "0" "N/A"
        ISSUES+=("$(jq -n \
            --arg severity "2" \
            --arg expected "Component $COMPONENT should be installed" \
            --arg actual "Component $COMPONENT not found in any namespace" \
            --arg title "Component $COMPONENT is missing in cluster ${CLUSTER}" \
            --arg reproduce_hint "${KUBERNETES_DISTRIBUTION_BINARY} get pods --all-namespaces -l app=$COMPONENT" \
            --arg next_steps "Install or verify Istio component installation" \
            '{severity: $severity, expected: $expected, actual: $actual, title: $title, reproduce_hint: $reproduce_hint, next_steps: $next_steps}')")
    fi
done

echo "-----------------------------------------------------------------------------------------------------------"

# Output issues if found
if [ "${#ISSUES[@]}" -gt 0 ]; then
    printf "[\n%s\n]\n" "$(IFS=,; echo "${ISSUES[*]}")" > "$ISSUES_FILE"
else
    echo "✅ All Istio control plane components are healthy."
fi
