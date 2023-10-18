#!/bin/bash

# Setup error handling
set -Euo pipefail
# Function to handle errors
function handle_error() {
    local line_number=$1
    local function_name=$2
    local error_code=$3
    echo "Error occurred in function '$function_name' at line $line_number with error code $error_code"
}
# Trap error signals to error handler function
trap 'handle_error $LINENO $FUNCNAME $?' ERR

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "kubectl command not found!"
    exit 1
fi

# Check for namespace argument
if [ -z "$NAMESPACE" ]; then
    echo "Please set the NAMESPACE environment variable"
    exit 1
fi

# Fetch all ServiceMonitors in the given namespace
SERVICEMONITORS=$(kubectl get servicemonitors -n "$NAMESPACE" -o json)

# Used to store report
MISSING_MONITORS=""
MISMATCHED_MONITORS=""
MATCHING_MONITORS=""
MONITOR_NAMES_TO_CHECK=()

SERVICEMONITOR_LIST=$(echo "$SERVICEMONITORS" | jq -rc '.items[] | {name: .metadata.name, selector: .spec.selector.matchLabels, port: .spec.endpoints[0].port} | tostring + "\n"')

# For each ServiceMonitor, get the service selector and port
for MONITOR in $SERVICEMONITOR_LIST; do
    SERVICE_SELECTOR=$(echo "$MONITOR" | jq -c '.selector')
    # rewrite to valid selector
    SERVICE_SELECTOR=$(echo "$SERVICE_SELECTOR" | jq -r 'to_entries[] | "\(.key)=\(.value)"' | tr '\n' ',' | sed 's/,$//')
    SERVICE_PORT=$(echo "$MONITOR" | jq -r '.port')
    MONITOR_NAME=$(echo "$MONITOR" | jq -r '.name')

    # Fetch services matching the selector
    MATCHING_SERVICES=$(kubectl get services -n "$NAMESPACE" -l "$SERVICE_SELECTOR" -o json | jq -r 'if has("items") then . else {items: [.] } end')
    MATCHING_SERVICES=$(echo "$MATCHING_SERVICES" | jq -rc '.items[] | {name: .metadata.name, ports: .spec.ports} | tostring + "\n"')

    SERVICE_EXISTS=false
    PORT_MATCHES=false

    # For each service, check if any of its ports match the ServiceMonitor's port
    for SERVICE in $MATCHING_SERVICES; do
        if [ -z "$SERVICE" ]; then
            continue
        fi

        SERVICE_NAME=$(echo "$SERVICE" | jq -r '.name')
        PORT_NAMES=$(echo "$SERVICE" | jq -r '.ports[].name')

        for PORT in $PORT_NAMES; do
            if [ "$PORT" == "$SERVICE_PORT" ]; then
                PORT_MATCHES=true
                SERVICE_EXISTS=true
            else
                PORT_MATCHES=false
                SERVICE_EXISTS=false
            fi
            # Output results
            if [ "$SERVICE_EXISTS" = true ]; then
                if [ "$PORT_MATCHES" = true ]; then
                    MATCHING_MONITORS+="\nServiceMonitor $MONITOR_NAME has a matching service $SERVICE_NAME with the correct port $(echo "$PORT_NAMES" | tr '\n' ',') in namespace $NAMESPACE."
                else
                    MISMATCHED_MONITORS+="\nServiceMonitor $MONITOR_NAME has a matching service $SERVICE_NAME but not the correct port $PORT_NAMES in namespace $NAMESPACE."
                    MONITOR_NAMES_TO_CHECK+=("$MONITOR_NAME")
                fi
            else
                MISSING_MONITORS+="\nNo service $SERVICE_NAME matches ServiceMonitor $MONITOR_NAME in namespace $NAMESPACE."
                MONITOR_NAMES_TO_CHECK+=("$MONITOR_NAME")

            fi
        done
    done
done
NEXTSTEPS="No next steps required."
if [ -z "$MATCHING_MONITORS" ]; then
    MATCHING_MONITORS="None detected"
fi
if [ -z "$MISMATCHED_MONITORS" ]; then
    MISMATCHED_MONITORS="None detected"
fi
if [ -z "$MISSING_MONITORS" ]; then
    MISSING_MONITORS="None detected"
fi

# Deduplicate contents
declare -A assoc_array
for item in "${MONITOR_NAMES_TO_CHECK[@]}"; do
    assoc_array["$item"]=1
done
MONITOR_NAMES_TO_CHECK=("${!assoc_array[@]}")
# Join for echo
delimiter=", "
output=""
for element in "${MONITOR_NAMES_TO_CHECK[@]}"; do
    if [ -z "$output" ]; then
        output="$element"
    else
        output="$output$delimiter$element"
    fi
done
MONITOR_NAMES=$output

if [ -n "$MISSING_MONITORS" ] || [ -n "$MISMATCHED_MONITORS" ]; then
    NEXTSTEPS="Investigate the endpoints of the following ServiceMonitors in the namespace $NAMESPACE as they appear to be misconfigured:\n$MONITOR_NAMES"
fi

cat <<EOF
Current State Of ServiceMonitors in $NAMESPACE:

OK:$(echo -e "$MATCHING_MONITORS")

Mismatch Detected:$(echo -e "$MISMATCHED_MONITORS")

Missing:$(echo -e "$MISSING_MONITORS")

Suggested Next Steps:$(echo -e "$NEXTSTEPS")

EOF

