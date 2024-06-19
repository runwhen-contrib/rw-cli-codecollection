#!/bin/bash

# Environment Variables:
# NAMESPACE
# CONTEXT
# WORKLOAD_NAME

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
