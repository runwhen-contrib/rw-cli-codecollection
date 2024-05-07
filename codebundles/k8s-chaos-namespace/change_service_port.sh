#!/bin/bash

# Environment Variables:
# NAMESPACE

CONFIGURED_PORT="9999"

# Get a random service name from the namespace
SERVICE_NAME=$(kubectl get services -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf -n 1)

# Get the current port of the service
CURRENT_PORT=$(kubectl get service $SERVICE_NAME -n $NAMESPACE -o jsonpath='{.spec.ports[0].port}')
echo "Current port of service $SERVICE_NAME: $CURRENT_PORT"

# Update the service's port to the configured value
kubectl patch service $SERVICE_NAME -n $NAMESPACE -p '{"spec":{"ports":[{"port":'$CONFIGURED_PORT'}]}}'

echo "Service $SERVICE_NAME port changed to $CONFIGURED_PORT"

# Echo all services with the configured port
echo "-----------------------------------"
echo "Current services with chaos port $CONFIGURED_PORT:"
kubectl get services -n $NAMESPACE | grep "$CONFIGURED_PORT"
echo "-----------------------------------"
