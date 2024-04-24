#!/bin/bash
source ./auth.sh

# Environment Variables:
# NAMESPACE

# Find a random pod in the given namespace
pod=$(kubectl get pods -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | shuf -n 1)

# Exec into the pod and create a file at /tmp/chaos
kubectl exec -n "$NAMESPACE" "$pod" -- touch /tmp/chaos

# Fill the file with random data until it consumes all space in the container
kubectl exec -n "$NAMESPACE" "$pod" -- sh -c "dd if=/dev/zero of=/tmp/chaos bs=1M count=1024"
