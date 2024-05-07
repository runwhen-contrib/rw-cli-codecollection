#!/bin/bash

# Environment Variables:
# NAMESPACE

CHAOS_LABEL="chaos"

# Get a random service name from the namespace
SERVICE_NAME=$(kubectl get services -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf -n 1)

# Get the current port of the service
SELECTOR=$(kubectl get service $SERVICE_NAME -n $NAMESPACE -o jsonpath='{.spec.selector}')
KEY=$(echo $SELECTOR | jq -r 'keys[0]')
VALUE=$(echo $SELECTOR | jq -r '.[keys[0]]')
echo "Current selector of service $SERVICE_NAME: $SELECTOR"
echo "Patching with chaos label..."
# Update the service's port to the configured value
kubectl patch service $SERVICE_NAME -n $NAMESPACE -p '{"spec":{"selector":{"'$KEY'":"'$CHAOS_LABEL'"}}}'

# # Echo all services with the chaos label
echo "-----------------------------------"
echo "Current services with chaos selector $CHAOS_LABEL:"
SERVICE_JSON=$(kubectl get services -n $NAMESPACE -ojson)
CHAOSED_SERVICES=$(kubectl get services -n $NAMESPACE -ojson | jq -r --arg CHAOS_LABEL "$CHAOS_LABEL" '.items[] | select(.spec.selector[] == $CHAOS_LABEL) | .metadata.name')
echo "-----------------------------------"
