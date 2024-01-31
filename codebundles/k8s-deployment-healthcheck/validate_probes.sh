#!/bin/bash

# Set deployment name and namespace
PROBE_TYPE="${1:-readinessProbe}"  # Default to livenessProbe, can be set to readinessProbe

# Function to extract data using jq
extract_data() {
    echo "$1" | jq -r "$2" 2>/dev/null
}

extract_port_from_command() {
    echo "$1" | grep -oE ':[0-9]+' | grep -oE '[0-9]+' | head -n 1
}

# Get deployment manifest in JSON format
MANIFEST=$(${KUBERNETES_DISTRIBUTION_BINARY} get deployment "$DEPLOYMENT_NAME" -n "$NAMESPACE" --context "$CONTEXT" -o json)
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
    CONTAINER_NAME=$(extract_data "$MANIFEST" ".spec.template.spec.containers[$i].name")
    echo "-------- START Validation - Container Name: $CONTAINER_NAME Probe Type: $PROBE_TYPE -------"
    echo "Container: \`$CONTAINER_NAME\`"
    echo "$PROBE_TYPE: $PROBE"

    # List container ports
    CONTAINER_PORTS=$(extract_data "$MANIFEST" ".spec.template.spec.containers[$i].ports[].containerPort")
    if [ -n "$CONTAINER_PORTS" ]; then
        echo "Exposed Ports: $CONTAINER_PORTS"
    else
        echo "No ports exposed."
    fi

    if [ -z "$PROBE" ]; then
        echo "Container \`$CONTAINER_NAME\`: ${PROBE_TYPE} not found."
        continue
    fi

    # Validate that the port in the probe is defined in the container's ports
    if echo "$PROBE" | jq -e '.httpGet, .tcpSocket' >/dev/null; then
        PROBE_PORT=$(extract_data "$PROBE" '.httpGet.port // .tcpSocket.port')
        CONTAINER_PORTS=$(extract_data "$MANIFEST" ".spec.template.spec.containers[$i].ports[].containerPort")

        if [[ ! " $CONTAINER_PORTS " == *"$PROBE_PORT"* ]]; then
            echo "Container \`$CONTAINER_NAME\`: Port $PROBE_PORT used in $PROBE_TYPE is not exposed by the container."
            next_steps+=("Update $PROBE_TYPE For \`${DEPLOYMENT_NAME}\` to use one of the following ports: $CONTAINER_PORTS")
        else
            echo "Container \`$CONTAINER_NAME\`: ${PROBE_TYPE} port $PROBE_PORT is valid."
        fi
    fi

    # Check if exec permissions are available (for exec type probes)
    if echo "$PROBE" | jq -e '.exec' >/dev/null; then
        IFS=$'\n' read -r -d '' -a EXEC_COMMAND_ARRAY < <(echo "$PROBE" | jq -r '.exec.command[]' && printf '\0')
        PORT_IN_COMMAND=$(extract_port_from_command "${EXEC_COMMAND_ARRAY[*]}")

        # Check if we see the port in the exec command, and if so, if it's defined in the manifest
        if [ -n "$PORT_IN_COMMAND" ]; then
            CONTAINER_PORTS=$(extract_data "$MANIFEST" ".spec.template.spec.containers[$i].ports[].containerPort")
            if [[ ! " $CONTAINER_PORTS " == *"$PORT_IN_COMMAND"* ]]; then
                echo "Container \`$CONTAINER_NAME\`: Port $PORT_IN_COMMAND used in ${PROBE_TYPE} exec command is not exposed by the container. The following ports are exposed: $CONTAINER_PORTS"
                next_steps+=("Get Deployment Workload Details For \`$DEPLOYMENT_NAME\`")
                next_steps+=("Remediate Readiness and Liveness Probes for Deployments in Namespace \`${NAMESPACE}\`")
            else
                echo "Container \`$CONTAINER_NAME\`: Port $PORT_IN_COMMAND in ${PROBE_TYPE} exec command is valid."
            fi
        fi

        # Check exec permission and execute command
        if ${KUBERNETES_DISTRIBUTION_BINARY} auth can-i create pods/exec -n "$NAMESPACE" >/dev/null 2>&1; then

            # Execute command
            echo "--- START Exec Test as configured----"
            echo "Executing command for deployment $DEPLOYMENT_NAME: ${EXEC_COMMAND_ARRAY[*]}"
            EXEC_OUTPUT=$(${KUBERNETES_DISTRIBUTION_BINARY} exec deployment/$DEPLOYMENT_NAME -n "$NAMESPACE" -- ${EXEC_COMMAND_ARRAY[*]} 2>&1)
            EXEC_EXIT_CODE=$?
            echo "Command Output: $EXEC_OUTPUT"
            echo "Exit Code: $EXEC_EXIT_CODE"
            echo "---- END Exec Test----"

            # Simple exec test to try substituting ports found in manifest
            if [[ -n "$CONTAINER_PORTS" && "$EXEC_EXIT_CODE" != 0 ]]; then
                for PORT in $CONTAINER_PORTS; do
                    MODIFIED_EXEC_COMMAND_ARRAY=("${EXEC_COMMAND_ARRAY[@]}")
                    for j in "${!MODIFIED_EXEC_COMMAND_ARRAY[@]}"; do
                        # Replace port placeholder with actual port
                        MODIFIED_EXEC_COMMAND_ARRAY[$j]=$(echo "${MODIFIED_EXEC_COMMAND_ARRAY[$j]}" | sed -r "s/:[0-9]+/:$PORT/")
                    done
                # Execute modified command
                    echo "--- START Exec Test with port $PORT"
                    echo "Executing modified command in deployment/$DEPLOYMENT_NAME with port $PORT: ${MODIFIED_EXEC_COMMAND_ARRAY[*]}"
                    EXEC_OUTPUT=$(kubectl exec deployment/$DEPLOYMENT_NAME -n "$NAMESPACE" -- "${MODIFIED_EXEC_COMMAND_ARRAY[@]}" 2>&1)
                    EXEC_EXIT_CODE=$?
                    echo "Command Output: $EXEC_OUTPUT"
                    echo "Exit Code: $EXEC_EXIT_CODE"
                    if [ $EXEC_EXIT_CODE == 0 ]; then
                        next_steps+=("Update $PROBE_TYPE For \`$DEPLOYMENT_NAME\` to use port $PORT")
                    fi
                    echo "--- END Exec Test----"
                done
            fi
        else
            echo "Exec permission is not available."
        fi
    fi
    echo "------- END Validation - Container Name: $CONTAINER_NAME Probe Type: $PROBE_TYPE -------"
done

# Display all unique recommendations that can be shown as Next Steps
if [[ ${#next_steps[@]} -ne 0 ]]; then
    printf "\nRecommended Next Steps: \n"
    printf "%s\n" "${next_steps[@]}" | sort -u
fi