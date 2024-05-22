#!/bin/bash

# Check if the service account has the necessary permissions
if ! kubectl auth can-i create nodes; then
    echo "Insufficient permissions to make node changes."
    exit 1
fi

READYNODES=$(kubectl get nodes | grep Ready | awk '{print $1}')

NODES=($READYNODES)

# Get random node
RANDOM_INDEX=$((RANDOM % ${#NODES[@]}))
RANDOM_NODE=${NODES[$RANDOM_INDEX]}

if [ -z "$RANDOM_NODE" ]; then
    echo "No suitable nodes found for draining."
    exit 1
fi

# Drain the node
kubectl drain $RANDOM_NODE --ignore-daemonsets
