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


# Try to parse out object details
# Splitting the extracted string to get individual parts
matched=$(echo "$messages" | grep -oP "\[\K(\w+\/\w+\/.+?)(?=\])")
owner_kind=$(echo "$matched" | cut -d'/' -f1)
owner_name=$(echo "$matched" | cut -d'/' -f2)
additional_details=$(echo "$matched" | cut -d'/' -f3-)

# Initialize an empty array to store recommendations
next_steps=()


if [[ $messages =~ "Health check failed" ]]; then
    next_steps+=("Troubleshoot $owner_kind Replicas for \`$owner_name\`")
    next_steps+=("Troubleshoot $owner_kind Warning Events for \`$owner_name\`")
fi



# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq
