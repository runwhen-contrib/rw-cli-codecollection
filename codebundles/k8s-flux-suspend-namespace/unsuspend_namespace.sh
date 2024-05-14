#!/bin/bash

# Environment Variables
# NAMESPACE

# FLUX_NAMESPACE_LABEL="kustomize.toolkit.fluxcd.io/namespace"
# FLUX_NAME_LABEL="kustomize.toolkit.fluxcd.io/name"

# Get all deployments, statefulsets, ingress, and services in NAMESPACE with selector FLUX_NAMESPACE_LABEL and FLUX_NAME_LABEL set
# For each resource, access the flux resource and unset spec.suspend using FLUX_NAMESPACE_LABEL and FLUX_NAME_LABEL to look it up
NAMESPACE_WORKLOADS=$(kubectl get all -n voting-app --selector=kustomize.toolkit.fluxcd.io/name  -oname)
for NAMESPACE_WORKLOAD in $NAMESPACE_WORKLOADS; do
    manifest_json=$(kubectl get $NAMESPACE_WORKLOAD -n voting-app -o json)
    flux_namespace=$(echo "$manifest_json" | jq -r '.metadata.labels["kustomize.toolkit.fluxcd.io/namespace"]')
    flux_object=$(echo "$manifest_json" | jq -r '.metadata.labels["kustomize.toolkit.fluxcd.io/name"]')
    suspend=$(echo "$manifest_json" | jq -r '.spec.suspend')
    if [[ $suspend == "true" ]]; then
        echo "Removing suspend from kustomizations.kustomize.toolkit.fluxcd.io/$flux_object in namespace $flux_namespace..."
        kubectl patch kustomizations.kustomize.toolkit.fluxcd.io/$flux_object -n $flux_namespace --type='json' -p '[{"op": "remove", "path": "/spec/suspend"}]'
    fi
done