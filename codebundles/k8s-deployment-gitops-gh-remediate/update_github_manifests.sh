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
    flux_source=$(echo "$flux_object_json" | jq -r .spec.sourceRef )
    flux_source_kind=$(echo "$flux_source" | jq -r .kind )
    flux_source_name=$(echo "$flux_source" | jq -r .name )
    flux_source_namespace=$(echo "$flux_source" | jq -r .namespace )
    flux_source_object=$(${KUBERNETES_DISTRIBUTION_BINARY} get $flux_source_kind $flux_source_name -n $flux_source_namespace --context $CONTEXT -o json)
    git_url=$(echo "$flux_source_object" | jq -r .spec.url )
    git_path=$(echo "$flux_object_json" | jq -r .spec.path)
}

update_github_manifests () {
    DATETIME=$(date '+%Y%m%d-%H%M%S')
    local git_url_no_suffix="${git_url%.git}"
    local git_owner=$(echo "$git_url_no_suffix" | awk -F '[/:]' '{print $(NF-1)}')
    local git_repo=$(echo "$git_url_no_suffix" | awk -F '[/:]' '{print $NF}')
    workdir=$(pwd)
    git clone $git_url 2>&1
    git config --global user.email "runsessions@runwhen.com" 2>&1
    git config --global user.name "RunWhen Runsession Bot" 2>&1
    git config --global pull.rebase false 2>&1
    git checkout -b "runwhen/manifest-update-$DATETIME"  2>&1
    git branch
    cd "$git_repo"
    # cd "$git_path"
    # Search for YAML files and process them
    find $git_path -type f -name '*.yaml' -o -name '*.yml' | while read yaml_file; do
        echo "Processing $yaml_file..."
        yq eval --inplace "
            select(.kind == \"Deployment\" and .metadata.name == \"$deployment_name\")
            | (.. | select(tag == \"!!str\")).style=\"\" | sub(\"$old_string\"; \"$new_string\")
        " "$yaml_file"
    done
    cd $workdir/$git_repo
    git branch
    pwd
    # Test if any git changes are made. If not, bail out and send instruction. 
    if git diff-index --quiet HEAD --; then 
        echo "No git changes detected"
        exit 0
    else
        echo "Changes detected. Pushing..."
        git add . 2>&1
        git commit -m "Manifest updates" 2>&1
        git status 2>&1 
        git push --set-upstream origin "runwhen/manifest-update-$DATETIME" 2>&1
        # PR_DATA=$(jq -n \
        #     --arg title "[runwhen] - Manifest update" \
        #     --arg body "check this out" \
        #     --arg head "runwhen/manifest-update-$DATETIME" \
        #     --arg base "main" \
        #     '{title: $title, body: $body, head: $head, base: $base}')
        # curl -X POST -H "Authorization: token $GITHUB_TOKEN" \
        #     -H "Accept: application/vnd.github.v3+json" \
        #     "https://api.github.com/repos/$git_owner/$git_repo/pulls" \
        #     -d "$PR_DATA"
    fi 
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
    object_type=$(jq -r '.object_type' <<< "$json_object")
    object_name=$(jq -r '.object_name' <<< "$json_object")
    probe_type=$(jq -r '.probe_type' <<< "$json_object")
    exec=$(jq -r '.exec' <<< "$json_object")
    invalid_command=$(jq -r '.invalid_command // empty' <<< "$json_object")
    invalid_ports=$(jq -r '.invalid_ports // empty' <<< "$json_object")

    # Logic to prefer invalid_command over invalid_oorts
    if [[ "$exec" == "true" && -n "$invalid_command" ]]; then
        echo "Processing $object_type $object_name with invalidCommand"
        find_gitops_info "$object_type" "$object_name"
        old_string=$invalid_command
        new_string=$valid_command
        update_github_manifests 

    elif [[ "$exec" == "true" && -n "$invalid_ports" ]]; then
        echo "Processing $object_type $object_name with invalidPorts"
        find_gitops_info "$object_type" "$object_name"
    fi
done
