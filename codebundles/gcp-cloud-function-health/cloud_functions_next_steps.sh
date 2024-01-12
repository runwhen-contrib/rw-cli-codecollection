#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# cloud function result and provides some generalized next steps.
# -----------------------------------------------------------------------------
# Input: List of event messages, function owner name

message="$1"
project_id="$2"

# Initialize an empty array to store recommendations
next_steps=()

# Split the message into an array of lines
IFS=$'\n' read -r -d '' -a lines <<< "$message"

# Function to process each line
process_line() {
    local line=$1

    if [[ $line =~ "CloudRunServiceNotFound" ]]; then
        next_steps+=("Get Error Logs for Unhealthy Cloud Functions in GCP Project \`$project_id\`")
    fi

    if [[ $line =~ "Unknown version or error. No message provided." ]]; then
        next_steps+=("Get Error Logs for Unhealthy Cloud Functions in GCP Project \`$project_id\`")
    fi

    if [[ $line =~ "Build failed" ]]; then
        if [[ $line =~ "For more details see the logs" ]]; then
            log_url=$(echo $line | grep -oP 'https?://[^\s]+' | sed 's/\.$//' )
            next_steps+=("Review the build logs at the [GCP Console URL]($log_url)")
        else
            next_steps+=("Get Build Logs for Failed Cloud Functions in GCP Project \`$project_id\`")
        fi 
    fi
}

# Process each line in the message
for line in "${lines[@]}"; do
    process_line "$line"
done

# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq
