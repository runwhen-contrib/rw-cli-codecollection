#!/bin/bash

# Environment Variables
# NAMESPACE
# CONTEXT
# WORKLOAD_NAME

selectors=$(kubectl get --context "$CONTEXT" -n "$NAMESPACE" "$WORKLOAD_NAME" -o jsonpath='{ .spec.selector.matchLabels }')
selectors=$(echo $selectors | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
echo "Fetching pods with label selector: $selectors"
pods=$(kubectl get --context "$CONTEXT" pods -n "$NAMESPACE" -l "$selectors" -o jsonpath='{.items[*].metadata.name}')

MAX_DELETIONS=1
echo "Killing a pod owned by "$WORKLOAD_NAME" in namespace $NAMESPACE"
deleted_count=0
for pod_name in $pods; do
    # Delete the pod
    kubectl delete --context $CONTEXT pod $pod_name -n $NAMESPACE
    # Increment the deleted count
    ((deleted_count++))
    # Check if we have deleted 10 pods
    if (( deleted_count >= MAX_DELETIONS )); then
        break
    fi
done

echo "Deletions complete. Current Pod States:"
kubectl get --context $CONTEXT pods -n $NAMESPACE
