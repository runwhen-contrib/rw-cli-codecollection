#!/bin/bash

# Environment Variables
# NAMESPACE
# CONTEXT

# FLUX_NAMESPACE_LABEL="kustomize.toolkit.fluxcd.io/namespace"
# FLUX_NAME_LABEL="kustomize.toolkit.fluxcd.io/name"

# Get all deployments, statefulsets, ingress, and services in NAMESPACE with selector FLUX_NAMESPACE_LABEL and FLUX_NAME_LABEL set
# For each resource, access the flux resource and set spec.suspend to true using FLUX_NAMESPACE_LABEL and FLUX_NAME_LABEL to look it up
NAMESPACE_WORKLOADS=$(kubectl get --context $CONTEXT all -n $NAMESPACE --selector=kustomize.toolkit.fluxcd.io/name  -oname)
processed_objects=()

for NAMESPACE_WORKLOAD in $NAMESPACE_WORKLOADS; do
    manifest_json=$(kubectl get --context $CONTEXT $NAMESPACE_WORKLOAD -n chaos-boutique -o json)
    flux_namespace=$(echo "$manifest_json" | jq -r '.metadata.labels["kustomize.toolkit.fluxcd.io/namespace"]')
    flux_object=$(echo "$manifest_json" | jq -r '.metadata.labels["kustomize.toolkit.fluxcd.io/name"]')

    # Skip if the flux_object has already been processed
    if [[ " ${processed_objects[@]} " =~ " ${flux_object} " ]]; then
        continue
    fi
    echo "Patching suspend onto kustomizations.kustomize.toolkit.fluxcd.io/$flux_object in namespace $flux_namespace..."
    kubectl patch --context $CONTEXT kustomizations.kustomize.toolkit.fluxcd.io/$flux_object -n $flux_namespace --type='merge' -p "{\"spec\":{\"suspend\":true}}"

    # Add the flux_object to the processed_objects array
    processed_objects+=("$flux_object")
done