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
messages="$1"
owner_kind="$2"  
owner_name="$3"

# Initialize an empty array to store recommendations
next_steps=()


if [[ $messages =~ "ContainersNotReady" && $owner_kind == "Deployment" ]]; then
    next_steps+=("Troubleshoot Deployment Replicas for \`$owner_name\`")
fi

if [[ $messages =~ "ImagePullBackOff" || $messages =~ "Back-off pulling image" ]]; then
    next_steps+=("List ImagePullBackoff Events and Test Path and Tags for Namespace \`$owner_name\`")
    next_steps+=("List Images and Tags for Every Container in Failed Pods for Namespace \`$owner_name\`")
fi

# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq
