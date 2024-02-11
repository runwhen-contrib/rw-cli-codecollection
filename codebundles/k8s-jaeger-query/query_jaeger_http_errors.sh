#!/bin/bash

# Assume NAMESPACE, KUBERNETES_DISTRIBUTION_BINARY, and CONTEXT are defined externally
# NAMESPACE="jaeger-namespace"
# KUBERNETES_DISTRIBUTION_BINARY="kubectl"
# CONTEXT="your-k8s-context"

# Define an array of label selectors to identify the Jaeger Query service
LABEL_SELECTORS=("app=jaeger,app.kubernetes.io/component=query" "app=jaeger-query")

# Initialize an empty array to hold the names of Jaeger services
JAEGER_SERVICES=()

# Iterate through the label selectors to find Jaeger Query services
for label in "${LABEL_SELECTORS[@]}"; do
    readarray -t services < <(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} get svc -n ${NAMESPACE} -l ${label} -o jsonpath='{.items[*].metadata.name}')
    # If services are found with the current label selector, add them to the JAEGER_SERVICES array
    if [ ${#services[@]} -gt 0 ]; then
        JAEGER_SERVICES+=("${services[@]}")
    fi
done

# Verify that at least one Jaeger Query service was found
if [ ${#JAEGER_SERVICES[@]} -eq 0 ]; then
    echo "Jaeger Query service not found in namespace ${NAMESPACE}"
    exit 1
fi

# Use the first found service for demonstration purposes
JAEGER_SERVICE_NAME=${JAEGER_SERVICES[0]}
echo "Jaeger Service Found: $JAEGER_SERVICE_NAME"

# Fetch all ports for the service
ports=$(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} get svc ${JAEGER_SERVICE_NAME} -n ${NAMESPACE} -o jsonpath='{.spec.ports[*].name}')

# Convert string to array
IFS=' ' read -r -a port_names <<< "$ports"

# Initialize JAEGER_PORT to an empty value
JAEGER_PORT=""

# Loop through all port names and check for your conditions
for port_name in "${port_names[@]}"; do
    if [[ "$port_name" == "query" || "$port_name" == "http-query" || "$port_name" == "query-http" ]]; then
        # If a matching port name is found, fetch its port number
        JAEGER_PORT=$(${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} get svc ${JAEGER_SERVICE_NAME} -n ${NAMESPACE} -o jsonpath="{.spec.ports[?(@.name==\"$port_name\")].port}")
        break # Assuming only one matching port is needed
    fi
done

if [ -z "$JAEGER_PORT" ]; then
    echo "Jaeger Query API port not found for service ${JAEGER_SERVICE_NAME}"
    exit 1
fi

echo "Found Jaeger Query API port: $JAEGER_PORT"

if [ -z "$JAEGER_PORT" ]; then
    echo "Jaeger Query API port not found for service ${JAEGER_SERVICE_NAME}"
    exit 1
fi

LOCAL_PORT=16686 # Local port for port-forwarding
REMOTE_PORT=$JAEGER_PORT

# Start port-forwarding in the background
${KUBERNETES_DISTRIBUTION_BINARY} --context=${CONTEXT} port-forward service/${JAEGER_SERVICE_NAME} ${LOCAL_PORT}:${REMOTE_PORT} -n ${NAMESPACE} &
PF_PID=$!

# Wait a bit for the port-forward to establish
sleep 5

# Jaeger Query base URL using the forwarded port
JAEGER_QUERY_BASE_URL="http://localhost:${LOCAL_PORT}"

# Your script's logic here
echo "Fetching all available services from Jaeger..."
services=$(curl -s "${JAEGER_QUERY_BASE_URL}/api/services" | jq -r '.data[]')
echo "Available services:"
echo "${services}"

# Cleanup: Stop the port-forwarding process
kill $PF_PID

echo "Script finished. Port-forwarding stopped."
