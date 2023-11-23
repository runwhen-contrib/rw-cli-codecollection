#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# Kubernetes based system and provides some generalized next steps based on the 
# content and frequency of the message. 
# -----------------------------------------------------------------------------
# Input: List of event messages, related owner kind, and related owner name
message="$1"
owner_kind="$2"  
owner_name="$3"

# Initialize an empty array to store recommendations
next_steps=()

get_storage_classes() {
    storage_classes=$(${KUBERNETES_DISTRIBUTION_BINARY} get storageclass.storage.k8s.io --context "$CONTEXT" -o json)
    storage_class_names=$(echo "$storage_classes" | jq -r '.items[].metadata.name')
    echo "${storage_class_names[@]}"
}

if [[ $message =~ storageclass\.storage\.k8s\.io.*not\ found ]]; then
    IFS=','
    storage_class_options=$(get_storage_classes)
    storage_class_options=$(echo "$storage_class_options" | sed -e ':a' -e 'N' -e '$!ba' -e 's/\n/", "/g' | awk '{print "[\"" $0 "\"]"}')
    next_steps+=("Fix Storage Class for \`$owner_name\` to one of: \`$storage_class_options\`")
fi



# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq
