#!/bin/bash
set -eo pipefail

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script is designed to take in some information about a  
# resource (typically a pod) and return it's owner.  
# NOTES: 
# Not sure if this is best served as a bash script or keyword
# This is quickly added and likely requires further expansion
# Not sure if it makes sense to keep this as a shared script, or 
# packaged multiple times with each codebundle depending on cases 
# -----------------------------------------------------------------------------

# Define the kind of resource, name (or part of it), namespace, and context
RESOURCE_KIND="$1"
RESOURCE_NAME="$2"
NAMESPACE="$3"
CONTEXT="$4"

# Command to get the Kubernetes distribution binary, for example, kubectl
KUBERNETES_DISTRIBUTION_BINARY="kubectl"

# Function to get the owner of a resource
get_owner() {
    local resource_name=$1
    local resource_kind=$2

    owner_kind=$(${KUBERNETES_DISTRIBUTION_BINARY} get $resource_kind $resource_name -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].kind}")
    if [ "$owner_kind" = "ReplicaSet" ]; then
        replicaset=$(${KUBERNETES_DISTRIBUTION_BINARY} get $resource_kind $resource_name -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}")
        deployment_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get replicaset $replicaset -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}")
        echo "Deployment $deployment_name"
    else
        owner_info=$(${KUBERNETES_DISTRIBUTION_BINARY} get $resource_kind $resource_name -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}")
        echo "$owner_kind $owner_info"
    fi
}

# Search for resources and get their owners
${KUBERNETES_DISTRIBUTION_BINARY} get $RESOURCE_KIND -n "${NAMESPACE}" --context="${CONTEXT}" | grep "${RESOURCE_NAME}" | awk '{print $1}' | \
while read resource_name; do
    if [ ! -z "$resource_name" ]; then
        get_owner "$resource_name" "$RESOURCE_KIND"
    fi
done | sort | uniq 