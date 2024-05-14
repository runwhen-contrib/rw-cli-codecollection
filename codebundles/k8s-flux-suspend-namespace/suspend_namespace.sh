#!/bin/bash

# Environment Variables
# NAMESPACE

# FLUX_NAMESPACE_LABEL="kustomize.toolkit.fluxcd.io/namespace"
# FLUX_NAME_LABEL="kustomize.toolkit.fluxcd.io/name"
FLUX_APPS_NAMESPACE="flux-system"

# Get all deployments, statefulsets, ingress, and services in NAMESPACE with selector FLUX_NAMESPACE_LABEL and FLUX_NAME_LABEL set
# For each resource, access the flux resource and set spec.suspend to true using FLUX_NAMESPACE_LABEL and FLUX_NAME_LABEL to look it up
NAMESPACE_WORKLOADS=$(kubectl get all -n $NAMESPACE --selector=kustomize.toolkit.fluxcd.io/name  -oname)
for NAMESPACE_WORKLOAD in $NAMESPACE_WORKLOADS; do
    manifest_json=$(kubectl get $NAMESPACE_WORKLOAD -n chaos-boutique -o json)
    flux_namespace=$(echo "$manifest_json" | jq -r '.metadata.labels["kustomize.toolkit.fluxcd.io/namespace"]')
    flux_object=$(echo "$manifest_json" | jq -r '.metadata.labels["kustomize.toolkit.fluxcd.io/name"]')
    if [[ "$flux_namespace" == "$FLUX_APPS_NAMESPACE" ]]; then
        echo "command: kubectl patch $flux_object -n $flux_namespace --type='merge' -p "{\"spec\":{\"suspend\":true}}" "
    fi
done