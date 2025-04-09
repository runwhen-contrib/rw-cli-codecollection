#!/bin/bash

# Function to check if a command exists
function check_command_exists() {
    if ! command -v "$1" &> /dev/null; then
        echo "Error: $1 could not be found"
        exit 1
    fi
}

# Function to check cluster connectivity
function check_cluster_connection() {
    # Check available contexts
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts "${CONTEXT}" --no-headers 2>&1 >/dev/null; then
        echo "=== Available Contexts ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" config get-contexts
        echo "Error: Unable to get cluster contexts"
        exit 1
    fi
    
    # Try cluster-info
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}" 2>&1 >/dev/null; then
        echo "=== Cluster Info ==="
        "${KUBERNETES_DISTRIBUTION_BINARY}" cluster-info --context="${CONTEXT}"
        echo "Error: Unable to connect to the cluster. Please check your kubeconfig and cluster status."
        exit 1
    fi
    
    # Check API server availability
    if ! "${KUBERNETES_DISTRIBUTION_BINARY}" get --raw="/api" --context="${CONTEXT}" 2>&1 >/dev/null; then
        echo "Error: Unable to reach Kubernetes API server"
        exit 1
    fi
}

# Function to handle JSON parsing errors
function check_jq_error() {
    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse JSON output"
        exit 1
    fi
}

# Verify required commands exist
check_command_exists "${KUBERNETES_DISTRIBUTION_BINARY}"
check_command_exists jq

# Check cluster connectivity first
check_cluster_connection

# Get namespaces where Istio components are installed
ISTIO_NAMESPACES=$(${KUBERNETES_DISTRIBUTION_BINARY} get namespaces --no-headers -o custom-columns=":metadata.name" --context="${CONTEXT}" | grep istio)

# Istio control plane components to check
ISTIO_COMPONENTS=("istiod" "istio-ingressgateway" "istio-egressgateway")

echo "🔍 Checking Istio Control Plane Components..."
echo "-----------------------------------------------------------------------------------------------------------"
printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" "Component" "Namespace" "Status" "Pods" "Restarts" "Warnings/Errors"
echo "-----------------------------------------------------------------------------------------------------------"

ALL_RUNNING=true
FOUND_WARNINGS=false
EVENTS_OUTPUT=""

for COMPONENT in "${ISTIO_COMPONENTS[@]}"; do
    COMPONENT_FOUND=false

    for NS in $ISTIO_NAMESPACES; do
        # Get all pods for the component
        PODS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods -n "$NS" -l app=$COMPONENT --no-headers -o custom-columns=":metadata.name" --context="${CONTEXT}")

        if [[ -n "$PODS" ]]; then
            COMPONENT_FOUND=true
            TOTAL_PODS=0
            RUNNING_PODS=0
            TOTAL_RESTARTS=0

            for POD in $PODS; do
                TOTAL_PODS=$((TOTAL_PODS + 1))

                # Check pod phase
                POD_STATUS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$POD" -n "$NS" -o jsonpath="{.status.phase}" --context="${CONTEXT}")
                if [[ "$POD_STATUS" == "Running" ]]; then
                    RUNNING_PODS=$((RUNNING_PODS + 1))
                fi

                # Get total restart count for all containers in the pod
                RESTARTS=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod "$POD" -n "$NS" -o jsonpath="{.status.containerStatuses[*].restartCount}" --context="${CONTEXT}")
                RESTARTS_SUM=0
                for COUNT in $RESTARTS; do
                    RESTARTS_SUM=$((RESTARTS_SUM + COUNT))
                done
                TOTAL_RESTARTS=$((TOTAL_RESTARTS + RESTARTS_SUM))

                # Check recent warnings/errors in events (last 1 hour)
                WARNINGS=$(${KUBERNETES_DISTRIBUTION_BINARY} get events -n "$NS" --field-selector involvedObject.name="$POD",type!=Normal --no-headers --context="${CONTEXT}" 2>/dev/null | wc -l)
                if [[ $WARNINGS -gt 0 ]]; then
                    FOUND_WARNINGS=true
                    EVENTS=$(${KUBERNETES_DISTRIBUTION_BINARY} get events -n "$NS" --field-selector involvedObject.name="$POD",type!=Normal --sort-by=.metadata.creationTimestamp --context="${CONTEXT}")
                    EVENTS_OUTPUT+="\n🔴 Warnings/Errors for Pod: $POD in Namespace: $NS\n$EVENTS\n"
                fi
            done

            if [[ $TOTAL_PODS -eq $RUNNING_PODS ]]; then
                STATUS="RUNNING"
            else
                STATUS="PARTIALLY RUNNING"
                ALL_RUNNING=false
            fi

            # Print component status
            printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" "$COMPONENT" "$NS" "$STATUS" "$RUNNING_PODS/$TOTAL_PODS" "$TOTAL_RESTARTS" "$WARNINGS"
        fi
    done

    # If component was not found in any namespace
    if [[ "$COMPONENT_FOUND" = false ]]; then
        printf "%-25s %-15s %-20s %-15s %-15s %-15s\n" "$COMPONENT" "N/A" "NOT INSTALLED" "0/0" "0" "N/A"
        ALL_RUNNING=false
    fi

done

echo "-----------------------------------------------------------------------------------------------------------"

if [ "$ALL_RUNNING" = true ]; then
    echo "✅ All Istio control plane components are up and running!"
else
    echo "❌ Some Istio components are missing or not fully running."
fi

if [ "$FOUND_WARNINGS" = true ]; then
    echo -e "\n🚨 Recent Non-Normal Events (Last 1 Hour)"
    echo "-----------------------------------------------------------------------------------------------------------"
    echo -e "$EVENTS_OUTPUT"
else
    echo "✅ No Warning/Error events found in the last hour."
fi
