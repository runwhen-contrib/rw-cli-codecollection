#!/bin/bash

# Environment Variables
# NAMESPACE

MAX_DELETIONS=10
POD_NAMES=$(kubectl get pods -oname -n $NAMESPACE)
echo "Starting random pod deletions in namespace $NAMESPACE"
deleted_count=0
for pod_name in $POD_NAMES; do
    # Roll a 50/50 chance
    if (( RANDOM % 2 == 0 )); then
        # Delete the pod
        kubectl delete $pod_name -n $NAMESPACE
        echo "Waiting between deletions..."
        sleep 3
        # Increment the deleted count
        ((deleted_count++))
    fi
    # Check if we have deleted 10 pods
    if (( deleted_count >= MAX_DELETIONS )); then
        break
    fi
done
