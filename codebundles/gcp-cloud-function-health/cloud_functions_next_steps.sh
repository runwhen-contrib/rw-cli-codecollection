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


if [[ $message =~ "CloudRunServiceNotFound" ]]; then
    next_steps+=("Get Logs for Failed Cloud Functions in GCP Project \`$project_id\`")
fi


if [[ $message =~ "Build failed" ]]; then
    if [[ $message =~ "For more details see the logs" ]]; then
        log_url=$(echo $message | grep -oP 'https?://[^\s]+' )
        next_steps+=("Review the build logs at the [GCP Console URL]($log_url)")
    else
        next_steps+=("Get Build Logs for Failed Cloud Functions in GCP Project \`$project_id\`")
    fi 
fi

# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq
