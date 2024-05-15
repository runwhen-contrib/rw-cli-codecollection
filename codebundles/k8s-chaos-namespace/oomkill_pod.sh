#!/bin/bash

# Environment Variables
# NAMESPACE

MAX_KILL=1
MEMORY_PRESSURE_AMOUNT=2147483648 # 2GB
POD_NAMES=$(kubectl get pods -oname -n $NAMESPACE --field-selector=status.phase=Running)
echo "Starting random pod oomkill in namespace $NAMESPACE"
killed_count=0
for pod_name in $POD_NAMES; do
    # Roll a 50/50 chance
    if (( RANDOM % 2 == 0 )); then
        echo "Creating background process to OOMkill pod $pod_name by applying pressure to $MEMORY_PRESSURE_AMOUNT of memory..."
        kubectl exec --context $CONTEXT -n $NAMESPACE $pod_name -- /bin/sh -c 'for i in 1 2 3 4 5; do (while :; do dd if=/dev/zero of=/dev/null bs=10485760  count=100 & done) & done'
        echo "Checking on pod..."
        pod_state=$(kubectl describe $pod_name -n $NAMESPACE)
        # Increment the killed count
        ((killed_count++))
    fi
    # Check if we have deleted 10 pods
    if (( killed_count >= MAX_KILL )); then
        break
    fi
done

sleep 30
echo "Current Pod States:"
kubectl get pods -n $NAMESPACE
