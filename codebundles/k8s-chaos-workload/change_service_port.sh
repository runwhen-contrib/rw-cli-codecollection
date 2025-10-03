#!/bin/bash

# Environment Variables:
# NAMESPACE
# CONTEXT
# WORKLOAD_NAME

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

CONFIGURED_PORT="9999"
service_to_mangle=""

workload_selectors=$(kubectl get --context "$CONTEXT" -n "$NAMESPACE" "$WORKLOAD_NAME" -o jsonpath='{ .spec.template.metadata.labels }')
workload_selectors=$(echo $workload_selectors | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
if [[ -z $workload_selectors ]]; then
    echo "No selectors found for workload $WORKLOAD_NAME, got '$workload_selectors'"
    exit 1
fi

services=$(kubectl get --context "$CONTEXT" services -n "$NAMESPACE" -oname)
for service in $services; do
    service_selectors=$(kubectl get --context "$CONTEXT" -n "$NAMESPACE" "$service" -o jsonpath='{ .spec.selector }')
    service_selectors=$(echo $service_selectors | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
    if [[ -z $service_selectors ]]; then
        echo "No selectors found for service $service, got '$service_selectors'"
        continue
    fi
    if [[ $workload_selectors == *"$service_selectors"* ]]; then
        echo "Service $service selects workload $WORKLOAD_NAME with $service_selectors on $workload_selectors"
        service_to_mangle=$service
    fi
done

if [[ -z $service_to_mangle ]]; then
    echo "No service found selecting the workload: $WORKLOAD_NAME"
    exit 1
fi

# Get the current port of the service
service_first_port=$(kubectl get --context $CONTEXT $service_to_mangle -n $NAMESPACE -o jsonpath='{.spec.ports[0]}')
port_name=$(echo "$service_first_port" | jq -r '.name')
port_protocol=$(echo "$service_first_port" | jq -r '.protocol')
port_target_port=$(echo "$service_first_port" | jq -r '.targetPort')
port_val=$(echo "$service_first_port" | jq -r '.port')
port_val=$(kubectl get --context $CONTEXT $service_to_mangle -n $NAMESPACE -o jsonpath='{.spec.ports[0].port}')
echo "Current port of service $service_to_mangle: $port_val"

# Update the service's port to the configured value
kubectl patch --context $CONTEXT $service_to_mangle -n $NAMESPACE --type='json' -p '[{"op": "replace", "path": "/spec/ports/0", "value": {"name": "'$port_name'", "protocol": "'$port_protocol'", "targetPort": '$port_target_port', "port": '$CONFIGURED_PORT'}}]'

echo "Service $service_to_mangle port changed to $CONFIGURED_PORT"

# Echo all services with the configured port
echo "-----------------------------------"
echo "Current services with chaos port $CONFIGURED_PORT:"
kubectl get --context $CONTEXT services -n $NAMESPACE | grep "$CONFIGURED_PORT"
echo "-----------------------------------"
