#!/bin/bash



# Define labels or annotations for identifying gitops resources

# Flux
declare -A flux_type_map
flux_type_map["kustomize"]="kustomization"
flux_label="toolkit.fluxcd.io"



# Function to find GitOps owner and Git manifest location
find_gitops_info() {
    local objectType="$1"
    local objectName="$2"
    # Replace the following line with the actual command or logic to find the GitOps owner and manifest
    echo "Finding GitOps info for $objectType $objectName..."
    # Dummy values for demonstration
    object_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get "$objectType" "$objectName" -n "$NAMESPACE" --context "$CONTEXT" -o json)
    
    flux_match=$(echo "$object_json" | grep "$flux_label")
    if [[ -n $flux_match ]]; then
        fetch_flux_owner_details "$object_json"
    else
        echo "No label containing '$flux_label' found in $objectType $objectName"
    fi

    # flux_label_match=$(echo "$object_json" | jq -r ".metadata.labels" | grep )
    # if [[ -n $flux_label_match ]]; then
    #     fetch_flux_owner_details(object=$object_json)
    # else
    #     echo "Label $flux_label does not exist in the $objectType $objectName"
    # fi
}

fetch_flux_owner_details() {
    local object_json="$1"
    echo "Processing Flux owner details..."
    # Get flux type
    flux_type=$(echo $object_json | jq -r '.metadata.labels | to_entries[] | select(.key | test("^[^.]+\\.toolkit\\.fluxcd\\.io/")) | .key | split(".")[0]' | uniq )
    flux_type_count=$(echo "$flux_type" | wc -l | awk '{print $1}')
    if [[ $flux_type_count -gt 1 ]]; then
        echo "Error: More than one flux type found" >&2
        exit 1
    fi
    flux_name=$(echo "$object_json" | jq -r --arg flux_type "$flux_type" '.metadata.labels[$flux_type + ".toolkit.fluxcd.io/name"]')
    flux_namespace=$(echo "$object_json" | jq -r --arg flux_type "$flux_type" '.metadata.labels[$flux_type + ".toolkit.fluxcd.io/namespace"]')
    flux_object_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get ${flux_type_map[$flux_type]} $flux_name -n $NAMESPACE --context $CONTEXT -o json)
    flux_source=$(echo "$flux_object_json" | jq .spec.sourceRef )
    flux_source_path=$(echo "$flux_object_json" | jq .spec.path )
    flux_source_kind=$(echo "$flux_source" | jq .kind )
    flux_source_name=$(echo "$flux_source" | jq ..name )
    flux_source_namespace=$(echo "$flux_source" | jq .namespace )
    flux_source_object=$($(${KUBERNETES_DISTRIBUTION_BINARY} get $flux_source_kind $flux_source_name -n $flux_source_namespace --context $CONTEXT -o json))
    git_url=$(echo "$flux_source_object" | jq .spec.url )
    update_github_manifests "$git_url"

}

update_github_manifests () {
    
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
