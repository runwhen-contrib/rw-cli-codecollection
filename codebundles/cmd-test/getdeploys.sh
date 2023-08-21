#!/bin/bash
myns=$NAMESPACE
myctxt=$CONTEXT
kubectl get deployments -n "$myns" --context $myctxt -ojson | jq -r '.items[].metadata.name'