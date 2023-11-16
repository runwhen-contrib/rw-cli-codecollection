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


# Display the list of recommendations
for next_step in "${next_steps[@]}"; do
    echo "$next_steps"
done