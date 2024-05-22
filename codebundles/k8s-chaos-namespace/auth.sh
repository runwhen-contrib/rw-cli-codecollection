#!/bin/bash

# Check if required kubectl environment variables set
if [[ -z $CONTEXT || -z $KUBECONFIG ]]; then
    echo "Missing required environment variables for kubectl: CONTEXT, KUBECONFIG"
    exit 1
fi
if [[ -f $KUBECONFIG ]]; then
    cat "$KUBECONFIG" > /tmp/kubeconfig
else
    echo "$KUBECONFIG" > /tmp/kubeconfig
fi
export KUBECONFIG="/tmp/kubeconfig"
kubectl config set-context "$CONTEXT" > /dev/null