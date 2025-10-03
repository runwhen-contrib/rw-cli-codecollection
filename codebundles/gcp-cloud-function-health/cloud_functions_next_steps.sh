#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# cloud function result and provides some generalized next steps.
# -----------------------------------------------------------------------------
# Input: List of event messages, function owner name

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
