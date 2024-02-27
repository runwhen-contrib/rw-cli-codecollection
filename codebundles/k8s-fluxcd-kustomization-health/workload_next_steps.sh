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

# Dynamically extract the pattern allowing for any object type
matched=$(echo "$messages" | grep -oP "\[\K.*?(?=\sstatus)")

# Extracting kind, namespace, and name
owner_kind=$(echo "$matched" | cut -d'/' -f1)
namespace=$(echo "$matched" | cut -d'/' -f2)
owner_name=$(echo "$matched" | cut -d'/' -f3)


# Initialize an empty array to store recommendations
next_steps=()

if [[ $messages =~ "Health check failed" ]]; then
    next_steps+=("Check $owner_kind Warning Events in '$namespace' namespace for '$owner_name'")
    next_steps+=("Troubleshoot $owner_kind Replicas in '$namespace' namespace for '$owner_name'")
fi

# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq