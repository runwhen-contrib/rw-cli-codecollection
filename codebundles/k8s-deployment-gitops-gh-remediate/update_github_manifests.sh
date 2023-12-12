#!/bin/bash

# Function to find GitOps owner and Git manifest location
find_gitops_info() {
    local objectType="$1"
    local objectName="$2"
    # Replace the following line with the actual command or logic to find the GitOps owner and manifest
    echo "Finding GitOps info for $objectType $objectName..."
    # Dummy values for demonstration
    echo "Owner: example-owner"
    echo "Manifest Location: example-location"
}

# Main script starts here
json_input="$1"

# Check if input is provided
if [[ -z "$json_input" ]]; then
    echo "No JSON input provided"
    exit 1
fi

# Process the JSON
jq -c '.[]' <<< "$json_input" | while read -r json_object; do
    objectType=$(jq -r '.objectType' <<< "$json_object")
    objectName=$(jq -r '.objectName' <<< "$json_object")
    probeType=$(jq -r '.probeType' <<< "$json_object")
    exec=$(jq -r '.exec' <<< "$json_object")
    invalidCommand=$(jq -r '.invalidCommand // empty' <<< "$json_object")
    invalidPorts=$(jq -r '.invalidPorts // empty' <<< "$json_object")

    # Logic to prefer invalidCommand over invalidPorts
    if [[ "$exec" == "true" && -n "$invalidCommand" ]]; then
        echo "Processing $objectType $objectName with invalidCommand"
        find_gitops_info "$objectType" "$objectName"
    elif [[ "$exec" == "true" && -n "$invalidPorts" ]]; then
        echo "Processing $objectType $objectName with invalidPorts"
        find_gitops_info "$objectType" "$objectName"
    fi
done
