#!/bin/bash

# Environment Variables
# NAMESPACE
# CONTEXT
# WORKLOAD_NAME

selectors=$(kubectl get --context "$CONTEXT" -n "$NAMESPACE" "$WORKLOAD_NAME" -o jsonpath='{ .spec.selector.matchLabels }')
selectors=$(echo "$selectors" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
echo "Fetching pods with label selector: $selectors"
pods=$(kubectl get --context "$CONTEXT" pods -n "$NAMESPACE" -l "$selectors" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

MAX_KILL=1
MEMORY_PRESSURE_AMOUNT=2147483648 # 2GB
echo "Starting $WORKLOAD_NAME random pod oomkill in namespace $NAMESPACE"
killed_count=0
for pod_name in $pods; do
    echo "Creating background process to OOMkill pod $pod_name by applying pressure to $MEMORY_PRESSURE_AMOUNT of memory..."
    kubectl exec --context $CONTEXT -n $NAMESPACE $pod_name -- /bin/sh -c 'for i in 1 2 3 4 5; do (while :; do dd if=/dev/zero of=/dev/null bs=2147483648  count=100 & done) & done'
    echo "Checking on pod..."
    sleep 3
    kubectl --context $CONTEXT describe $pod_name -n $NAMESPACE
    # Increment the killed count
    ((killed_count++))
    # Check if we have deleted 10 pods
    if (( killed_count >= MAX_KILL )); then
        break
    fi
done
echo "Current Pod States:"
kubectl get --context $CONTEXT pods -n $NAMESPACE
