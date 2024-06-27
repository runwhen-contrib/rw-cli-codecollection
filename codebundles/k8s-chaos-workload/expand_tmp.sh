#!/bin/bash

# Environment Variables:
# NAMESPACE
# CONTEXT
# WORKLOAD_NAME

selectors=$(kubectl get --context "$CONTEXT" -n "$NAMESPACE" "$WORKLOAD_NAME" -o jsonpath='{ .spec.selector.matchLabels }')
selectors=$(echo $selectors | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
echo "Fetching pods with label selector: $selectors"
pods=$(kubectl get --context "$CONTEXT" pods -n "$NAMESPACE" -l "$selectors" -o jsonpath='{.items[*].metadata.name}')

# Find a random pod in the given namespace
pod=$(echo $pods | tr ' ' '\n' | shuf -n 1)

echo "Expanding /tmp of pod $pod in namespace $NAMESPACE"

# Exec into the pod and create a file at /tmp/chaos
kubectl exec --context $CONTEXT -n "$NAMESPACE" "$pod" -- touch /tmp/chaos

# Fill the file with random data until it consumes all space in the container
kubectl exec --context $CONTEXT -n "$NAMESPACE" "$pod" -- sh -c "dd if=/dev/zero of=/tmp/chaos bs=1M count=1024"
