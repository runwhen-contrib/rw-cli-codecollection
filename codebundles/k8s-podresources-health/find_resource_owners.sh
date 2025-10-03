#!/bin/bash
# set -eo pipefail

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
# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

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
    if [ "$owner_kind" = "" ]; then
        # No owner reference means there is no parent object. Return the direct object.
        echo "$resource_kind $resource_name"
    elif [ "$owner_kind" = "ReplicaSet" ]; then
        replicaset=$(${KUBERNETES_DISTRIBUTION_BINARY} get $resource_kind $resource_name -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}")
        deployment_name=$(${KUBERNETES_DISTRIBUTION_BINARY} get replicaset $replicaset -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}")
        echo "Deployment $deployment_name"
    else
        owner_info=$(${KUBERNETES_DISTRIBUTION_BINARY} get $resource_kind $resource_name -n "${NAMESPACE}" --context="${CONTEXT}" -o=jsonpath="{.metadata.ownerReferences[0].name}")
        echo "$owner_kind $owner_info"
    fi
}


resources=$(${KUBERNETES_DISTRIBUTION_BINARY} get $RESOURCE_KIND -n "${NAMESPACE}" --context="${CONTEXT}" | grep "${RESOURCE_NAME}" | awk '{print $1}' || true)

if [ -z "$resources" ]; then
    echo "No resource found"
else
    while read resource_name; do
        if [ ! -z "$resource_name" ]; then
            owner=$(get_owner "$resource_name" "$RESOURCE_KIND")
            if [ -n "$owner" ]; then
                echo "$owner" | tr -d '\n'
                exit 0
            fi
        fi
    done <<< $resources
fi