#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# Kubernetes based system and provides some generalized next steps based on the 
# content of the messages.
# -----------------------------------------------------------------------------
# Input: List of event messages, related owner kind, and related owner name
messages="$1"
certificate_name="$2"  
issuer="$3"

# Initialize an empty array to store recommendations
next_steps=()


if [[ $messages =~ "Referenced Issuer not found" ]]; then
    next_steps+=("Check spelling or configuration of Issuer \`$issuer\`")
fi

if [[ $messages =~ "Waiting on certificate issuance" ]]; then
    next_steps+=("Check Certificate Issuer Events for Issuer \`$issuer\`")
fi

# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq
