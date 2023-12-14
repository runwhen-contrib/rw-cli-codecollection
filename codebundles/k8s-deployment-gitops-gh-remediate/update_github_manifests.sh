#!/bin/bash


declare -a next_steps=()


# Define labels or annotations for identifying gitops resources
# Flux
declare -A flux_type_map
# TODO - add additional flux resource types like helmrelease
flux_type_map["kustomize"]="kustomization"
flux_label="toolkit.fluxcd.io"

# Argo (placeholder)

# Function to find GitOps owner and Git manifest location
find_gitops_info() {
    local objectType="$1"
    local objectName="$2"
    echo "Finding GitOps info for $objectType $objectName..."
    object_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get "$objectType" "$objectName" -n "$NAMESPACE" --context "$CONTEXT" -o json)
    
    # Check if the object is from Flux
    flux_match=$(echo "$object_json" | grep "$flux_label")
    if [[ -n $flux_match ]]; then
        fetch_flux_owner_details "$object_json"
    else
        echo "No label containing '$flux_label' found in $objectType $objectName"
    fi

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

## Argo placeholder
# fetch_argo_owner_details() {

# }

update_github_manifests () {
    DATETIME=$(date '+%Y%m%d-%H%M%S')
    local git_url_no_suffix="${git_url%.git}"
    local git_owner=$(echo "$git_url_no_suffix" | awk -F '[/:]' '{print $(NF-1)}')
    local git_repo=$(echo "$git_url_no_suffix" | awk -F '[/:]' '{print $NF}')
    git config --global user.email "runsessions@runwhen.com" 2>&1
    git config --global user.name "RunWhen Runsession Bot" 2>&1
    git config --global pull.rebase false 2>&1

    workdir=$(pwd)
    git clone $git_url 2>&1
    cd $workdir/$git_repo
    git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$git_owner/$git_repo
    git checkout -b "runwhen/manifest-update-$DATETIME"  2>&1
    git branch
    # Search for YAML files and process them
    find $git_path -type f -name '*.yaml' -o -name '*.yml' | while read yaml_file; do
        echo "object name: $object_name"
        echo "old string: $old_string"
        echo "new string: $new_string"
        $substitution_function
    done

    # Test if any git changes are made. If not, bail out and send instruction. If so, commit and PR.  
    cd $workdir/$git_repo
    if git diff-index --quiet HEAD --; then 
        echo "No git changes detected"
        exit 0
    else
        echo "Changes detected. Pushing..."
        git add . 2>&1
        git commit -m "Manifest updates" 2>&1
        git status 2>&1 
        git push -f -v --set-upstream origin "runwhen/manifest-update-$DATETIME"
        generate_pull_request_body_content
        PR_DATA=$(jq -n \
            --arg title "[RunWhen] - GitOps Manifest Updates for $object_type $object_name" \
            --arg body "$PR_BODY" \
            --arg head "runwhen/manifest-update-$DATETIME" \
            --arg base "main" \
            '{title: $title, body: $body, head: $head, base: $base}')
        pr_output=$(curl -X POST -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/$git_owner/$git_repo/pulls" \
            -d "$PR_DATA")
        pr_html_url=$(jq -r '.html_url // empty' <<< "$pr_output")
        next_steps+=("View proposed Github changes in [Pull Request]($pr_html_url)")
    fi 
}

probe_exec_substitution () {
    # Convert the old and new strings into array elements
    IFS=' ' read -ra old_string_array <<< "$old_string"
    IFS=' ' read -ra new_string_array <<< "$new_string"

    # Use yq to iterate over each element in the command array and replace it if it matches
    for i in "${!old_string_array[@]}"; do
        yq e "(select(.kind == \"Deployment\" and .metadata.name == \"$object_name\").spec.template.spec.containers[] | select(.name == \"$container\").$probe_type.exec.command[] | select(. == \"${old_string_array[$i]}\") ) |= \"${new_string_array[$i]}\"" -i "$yaml_file"
    done

}

generate_pull_request_body_content () {
runsession_url=$RW_FRONTEND_URL/map/$RW_WORKSPACE#selectedRunSessions=$RW_SESSION_ID

read -r -d '' PR_BODY << EOF
### RunSession Details

A RunSession (started by $RW_USERNAME) with the following tasks has produced this Pull Request: 

- $RW_TASK_TITLES

To view the RunSession, click [this link]($runsession_url)

### Change Details
$change_summary

The following details prompted this change: 
\`\`\`
$json_pretty
\`\`\`

---
[RunWhen Workspace]($RW_FRONTEND_URL/map/$RW_WORKSPACE)
EOF

}


# Main script starts here
json_input="$1"

# Check if input is provided
if [[ -z "$json_input" ]]; then
    echo "No JSON input provided"
    exit 1
fi

# Process the JSON
while read -r json_object; do
    json_pretty=$(echo $json_object | jq .)
    object_type=$(jq -r '.object_type' <<< "$json_object")
    object_name=$(jq -r '.object_name' <<< "$json_object")
    remediation_type=$(jq -r '.remediation_type' <<< "$json_object")
    probe_type=$(jq -r '.probe_type' <<< "$json_object")
    exec=$(jq -r '.exec' <<< "$json_object")
    invalid_command=$(jq -r '.invalid_command // empty' <<< "$json_object")
    valid_command=$(jq -r '.valid_command // empty' <<< "$json_object")
    invalid_ports=$(jq -r '.invalid_ports // empty' <<< "$json_object")
    valid_ports=$(jq -r '.valid_ports // empty' <<< "$json_object")
    container=$(jq -r '.container // empty' <<< "$json_object")

    # Logic to prefer invalid_command over invalid_oorts
    if [[ "$remediation_type" == "probe_update" ]]; then
        if [[ "$exec" == "true" && -n "$invalid_command" ]]; then
            echo "Processing $object_type $object_name with invalidCommand"
            find_gitops_info "$object_type" "$object_name"
            old_string=$invalid_command
            new_string=$valid_command
            substitution_function=probe_exec_substitution
            change_summary="Container \`$container\` in $object_type \`$object_name\` had an invalid exec command for $probe_type. The updated command is \`$valid_command\`"
            update_github_manifests 

        elif [[ "$exec" == "true" && -n "$invalid_ports" ]]; then
            echo "Processing $object_type $object_name with invalidPorts"
            find_gitops_info "$object_type" "$object_name"
        fi
    fi
done < <(jq -c '.[]' <<< "$json_input")


# Display all unique recommendations that can be shown as Next Steps
if [[ ${#next_steps[@]} -ne 0 ]]; then
    printf "\nRecommended Next Steps: \n"
    printf "%s\n" "${next_steps[@]}" | sort -u
fi
