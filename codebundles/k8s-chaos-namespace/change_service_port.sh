#!/bin/bash

# Environment Variables:
# NAMESPACE

CONFIGURED_PORT="9999"

# Get a random service name from the namespace
SERVICE_NAME=$(kubectl get services -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf -n 1)

# Get the current port of the service
service_first_port=$(kubectl get service $SERVICE_NAME -n $NAMESPACE -o jsonpath='{.spec.ports[0]}')
port_name=$(echo "$service_first_port" | jq -r '.name')
port_protocol=$(echo "$service_first_port" | jq -r '.protocol')
port_target_port=$(echo "$service_first_port" | jq -r '.targetPort')
port_val=$(echo "$service_first_port" | jq -r '.port')
port_val=$(kubectl get service $SERVICE_NAME -n $NAMESPACE -o jsonpath='{.spec.ports[0].port}')
echo "Current port of service $SERVICE_NAME: $port_val"

# Update the service's port to the configured value
kubectl patch service $SERVICE_NAME -n $NAMESPACE --type='json' -p '[{"op": "replace", "path": "/spec/ports/0", "value": {"name": "'$port_name'", "protocol": "'$port_protocol'", "targetPort": '$port_target_port', "port": '$CONFIGURED_PORT'}}]'

echo "Service $SERVICE_NAME port changed to $CONFIGURED_PORT"

# Echo all services with the configured port
echo "-----------------------------------"
echo "Current services with chaos port $CONFIGURED_PORT:"
kubectl get services -n $NAMESPACE | grep "$CONFIGURED_PORT"
echo "-----------------------------------"
