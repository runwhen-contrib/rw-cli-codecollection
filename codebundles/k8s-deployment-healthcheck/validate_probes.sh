#!/bin/bash

# Set deployment name and namespace
PROBE_TYPE="${1:-livenessProbe}"  # Default to livenessProbe, can be set to readinessProbe

# Function to extract data using jq
extract_data() {
    echo "$1" | jq -r "$2" 2>/dev/null
}

# Get deployment manifest in JSON format
MANIFEST=$(kubectl get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --context "$CONTEXT"-o json)
if [ $? -ne 0 ]; then
    echo "Error fetching deployment details: $MANIFEST"
    exit 1
fi

# Get number of containers
NUM_CONTAINERS=$(extract_data "$MANIFEST" '.spec.template.spec.containers | length')
if [ -z "$NUM_CONTAINERS" ]; then
    echo "No containers found in deployment."
    exit 1
fi

# Loop through containers and validate probes
for ((i=0; i<NUM_CONTAINERS; i++)); do
    PROBE=$(extract_data "$MANIFEST" ".spec.template.spec.containers[$i].${PROBE_TYPE}")
    if [ -z "$PROBE" ]; then
        echo "Container $i: ${PROBE_TYPE} not found."
        continue
    fi

    # Validate that the port in the probe is defined in the container's ports
    if echo "$PROBE" | jq -e '.httpGet, .tcpSocket' >/dev/null; then
        PROBE_PORT=$(extract_data "$PROBE" '.httpGet.port // .tcpSocket.port')
        CONTAINER_PORTS=$(extract_data "$MANIFEST" ".spec.template.spec.containers[$i].ports[].containerPort")

        if [[ ! " $CONTAINER_PORTS " == *"$PROBE_PORT"* ]]; then
            echo "Container $i: Port $PROBE_PORT used in ${PROBE_TYPE} is not exposed by the container."
        else
            echo "Container $i: ${PROBE_TYPE} port $PROBE_PORT is valid."
        fi
    fi

    # Check if exec permissions are available (for exec type probes)
    if echo "$PROBE" | jq -e '.exec' >/dev/null; then
        if kubectl auth can-i exec pod -n "$NAMESPACE" >/dev/null 2>&1; then
            echo "Container $i: Exec permission is available."
        else
            echo "Container $i: Exec permission is not available."
        fi
    fi
done
