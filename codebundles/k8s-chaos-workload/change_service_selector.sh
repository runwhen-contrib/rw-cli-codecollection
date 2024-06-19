#!/bin/bash

# Environment Variables:
# NAMESPACE
# CONTEXT
# WORKLOAD_NAME

service_to_mangle=""
CHAOS_LABEL="chaos"

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
SELECTOR=$(kubectl get --context $CONTEXT $service_to_mangle -n $NAMESPACE -o jsonpath='{.spec.selector}')
KEY=$(echo $SELECTOR | jq -r 'keys[0]')
VALUE=$(echo $SELECTOR | jq -r '.[keys[0]]')
echo "Current selector of service $service_to_mangle: $SELECTOR"
echo "Patching with chaos label..."
# Update the service's port to the configured value
kubectl patch --context $CONTEXT $service_to_mangle -n $NAMESPACE -p '{"spec":{"selector":{"'$KEY'":"'$CHAOS_LABEL'"}}}'

# # Echo all services with the chaos label
echo "-----------------------------------"
echo "Current services with chaos selector $CHAOS_LABEL:"
SERVICE_JSON=$(kubectl get --context $CONTEXT services -n $NAMESPACE -ojson)
CHAOSED_SERVICES=$(echo "$SERVICE_JSON" | jq -r '.items[] | select(.spec.selector == {"'$KEY'":"'$CHAOS_LABEL'"}) | .metadata.name')
echo $CHAOSED_SERVICES
echo "-----------------------------------"
