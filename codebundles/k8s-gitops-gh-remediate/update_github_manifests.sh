#!/bin/bash


declare -a next_steps=()
declare -A change_list
declare -A substitutions_list
declare -A change_details
declare -A change_summary



## GitOps Owner Logic
#########################
# Define labels or annotations for identifying gitops resources
# Flux
declare -A flux_type_map
# TODO - add additional flux resource types like helmrelease
flux_type_map["kustomize"]="kustomization"
flux_label="toolkit.fluxcd.io"

# ArgoCD (placeholder)
argocd_type_map["project"]="project"
argocd_label="argocd.argoproj.io/instance"

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

    # Check if the object is from Argo
    argocd_match=$(echo "$object_json" | grep "$argocd_label")
    if [[ -n $argocd_match ]]; then
        fetch_argocd_owner_details "$object_json"
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
    echo "Command \`$KUBERNETES_DISTRIBUTION_BINARY get ${flux_type_map[$flux_type]} $flux_name -n $flux_namespace --context $CONTEXT -o json\`"
    flux_object_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get ${flux_type_map[$flux_type]} $flux_name -n $flux_namespace --context $CONTEXT -o json)
    flux_source=$(echo "$flux_object_json" | jq -r .spec.sourceRef )
    flux_source_kind=$(echo "$flux_source" | jq -r .kind )
    flux_source_name=$(echo "$flux_source" | jq -r .name )
    flux_source_namespace=$(echo "$flux_source" | jq -r .namespace )
    # Check if flux_source_namespace is empty, which likely means that it's
    # referring to the same namespace as $flux_namespace
    if [[ -n $flux_source_namespace ]]; then 
        flux_source_namespace=$flux_namespace
    fi
    flux_source_object=$(${KUBERNETES_DISTRIBUTION_BINARY} get $flux_source_kind $flux_source_name -n $flux_source_namespace --context $CONTEXT -o json)
    git_url=$(echo "$flux_source_object" | jq -r .spec.url )
    git_path=$(echo "$flux_object_json" | jq -r .spec.path)
    git_branch=$(echo "$flux_source_object" | jq -r .spec.ref.branch)
    echo "Found FluxCD resource name: $flux_name, type: $flux_type, namespace: $flux_namespace, source: $flux_source, source_kind: $flux_source_kind, source_name: $flux_source_name, source_namespace: $flux_source_namespace, source_object: $flux_source_object, git_url: $git_url, git_path: $git_path"
}

## Argo placeholder
fetch_argocd_owner_details() {
    local object_json="$1"
    echo "Processing ArgoCD owner details..."
    # Get argo instance name
    argocd_instance=jq '.items[] | select(.metadata.labels."argocd.argoproj.io/instance") | .metadata.labels."argocd.argoproj.io/instance"'
    application_namespace=$(awk -F '_' '{print $1}' <<< $argocd_instance)
    application_name=$(awk -F '_' '{print $2}' <<< $argocd_instance)
    argocd_object_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get application $application_name -n $application_namespace --context $CONTEXT -o json)
    git_url=$(echo "$argocd_object_json" | jq -r .spec.source.repoURL )
    git_path=$(echo "$argocd_object_json" | jq -r .spec.source.path )
    git_branch=$(echo "$argocd_object_json" | jq -r .spec.source.targetRevision )
    echo "Found ArgoCD application name: $application_name, namespace: $application_namespace, source_object: $argocd_object_json, git_url: $git_url, git_path: $git_path, git_branch: $git_branch"
}

## Substitution Functions
#########################
probe_exec_substitution () {
    IFS=',' read container probe_type old_string new_string invalid_ports valid_ports <<< "$substitution"

    # Convert the old and new strings into array elements
    IFS=' ' read -ra old_string_array <<< "$old_string"
    IFS=' ' read -ra new_string_array <<< "$new_string"

    # Use yq to iterate over each element in the command array and replace it if it matches
    for i in "${!old_string_array[@]}"; do
        yq e "(select(.kind == \"$object_type\" and .metadata.name == \"$object_name\").spec.template.spec.containers[] | select(.name == \"$container\").$probe_type.exec.command[] | select(. == \"${old_string_array[$i]}\") ) |= \"${new_string_array[$i]}\"" -i "$yaml_file"
    done

}

resource_quota_substitution () {
    IFS=',' read quota_name resource current_value suggested_value <<< "$substitution"
    yq e "(select(.kind == \"ResourceQuota\" and .metadata.name == \"$quota_name\").spec.hard.\"$resource\") |= sub(\"$current_value\"; \"$suggested_value\")" -i "$yaml_file"
}
pvc_increase () {
    IFS=',' read pvc_name pod current_size recommended_size <<< "$substitution"
    yq e "(select(.kind == \"PersistentVolumeClaim\" and .metadata.name == \"$pvc_name\").spec.resources.requests.storage) |= sub(\"$current_size\"; \"$recommended_size\")" -i "$yaml_file"
} 

resource_request_substitution () {
    IFS=',' read container resource current_value suggested_value <<< "$substitution"
    if yq e "select(.kind == \"$object_type\" and .metadata.name == \"$object_name\")" "$yaml_file" | grep -q "$container"; then
        yq e ".spec.template.spec.containers |= map(select(.name == \"$container\").resources.requests.$resource |= sub(\"$current_value\"; \"$suggested_value\")) | select(.kind == \"$object_type\" and .metadata.name == \"$object_name\")" "$yaml_file"
        yq e ".spec.template.spec.containers |= map(select(.name == \"$container\").resources.requests.$resource |= sub(\"$current_value\"; \"$suggested_value\")) | select(.kind == \"$object_type\" and .metadata.name == \"$object_name\")" -i "$yaml_file"
    else
        echo "No matching path found in $yaml_file"
    fi
}


## GitHub Pull Request Functions
#########################
generate_pull_request_body_content () {
    runsession_url=$RW_FRONTEND_URL/map/$RW_WORKSPACE#selectedRunSessions=$RW_SESSION_ID

    read -r -d '' PR_BODY << EOF
### RunSession Details

A RunSession (started by $RW_USERNAME) with the following tasks has produced this Pull Request: 

- $RW_TASK_TITLES

To view the RunSession, click [this link]($runsession_url)

### Change Details
${change_summary[@]}

The following details prompted this change: 
\`\`\`
${change_details[@]}
\`\`\`

---
[RunWhen Workspace]($RW_FRONTEND_URL/map/$RW_WORKSPACE)
EOF
}

update_github_manifests () {
    DATETIME=$(date '+%Y%m%d-%H%M%S')

    local git_url_no_suffix="${git_url%.git}"
    local git_owner=$(echo "$git_url_no_suffix" | awk -F '[/:]' '{print $(NF-1)}')
    local git_repo=$(echo "$git_url_no_suffix" | awk -F '[/:]' '{print $NF}')
    git config --global user.email "runsessions@runwhen.com" 2>&1
    git config --global user.name "RunWhen Runsession Bot" 2>&1
    git config --global pull.rebase false 2>&1

    # Create a temporary directory in $HOME
    tempdir=$(mktemp -d "$HOME/tempdir.XXXXXX")
    trap 'rm -rf -- "$tempdir"' EXIT
    workdir="$tempdir"
    cd $workdir
    git clone $git_url 2>&1
    cd $workdir/$git_repo
    git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$git_owner/$git_repo
    git checkout -b "runwhen/manifest-update-$DATETIME"  2>&1
    git branch
    # Search for YAML files and process them
    find $git_path -type f -name '*.yaml' -o -name '*.yml' | while read yaml_file; do
        echo $yaml_file
        IFS=';' read -ra substitutions <<< "${substitutions_list[$object_id]}"
        for substitution in "${substitutions[@]}"; do
                $substitution_function
        done
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
            --arg title "[RunWhen] - GitOps Manifest Updates for $object_id" \
            --arg body "$PR_BODY" \
            --arg head "runwhen/manifest-update-$DATETIME" \
            --arg base "$git_branch" \
            '{title: $title, body: $body, head: $head, base: $base}')
        echo "PR_DATA:\n$PR_DATA"
        pr_output=$(curl -X POST -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github.v3+json" \
            "https://api.github.com/repos/$git_owner/$git_repo/pulls" \
            -d "$PR_DATA")
        echo "pr_output:\n$pr_output"
        pr_html_url=$(jq -r '.html_url // empty' <<< "$pr_output")
        next_steps+=("View proposed Github changes in [Pull Request]($pr_html_url)")
    fi 
}

## Main code
#########################
json_input="$1"

# Check if input is provided
if [[ -z "$json_input" ]]; then
    echo "No JSON input provided"
    exit 1
fi


# # Process the JSON
while read -r json_object; do
    remediation_type=$(jq -r '.remediation_type' <<< "$json_object")
    echo $json_object
    object_type=$(jq -r '.object_type' <<< "$json_object")
    object_name=$(jq -r '.object_name' <<< "$json_object")
    object_id="$object_type-$object_name"
    change_list[$object_id]+="$json_object\n"
done < <(jq -c '.[]' <<< "$json_input")

for object_id in "${!change_list[@]}"; do
    echo "Processing changes for $object_id"
    find_gitops_info "$object_type" "$object_name"

    # Reset change summary and details for this batch
    change_summary=""
    change_details=""

    while read -r json_object; do
        remediation_type=$(jq -r '.remediation_type' <<< "$json_object")
        # Set other necessary variables from json_object
        json_pretty=$(echo $json_object | jq .)
        if [[ "$remediation_type" == "resourcequota_update" ]]; then
            increase_percentage=$(jq -r '.increase_percentage // empty' <<< "$json_object")
            quota_name=$(jq -r '.quota_name // empty' <<< "$json_object")
            resource=$(jq -r '.resource // empty' <<< "$json_object")
            usage=$(jq -r '.usage // empty' <<< "$json_object")
            current_value=$(jq -r '.current_value // empty' <<< "$json_object")
            suggested_value=$(jq -r '.suggested_value // empty' <<< "$json_object")
            echo "Increasing ResourceQuota $quota_name with usage $usage by $increase_percentage% to $suggested_value"
            substitutions_list[$object_id]+="$quota_name,$resource,$current_value,$suggested_value;"
            substitution_function=resource_quota_substitution     
            change_summary+="[Change] Increasing ResourceQuota \`$quota_name\` for \`$resource\` to \`$suggested_value\` in namespace \`$NAMESPACE\`.<br>"
            change_details+="$json_pretty"
        elif [[ "$remediation_type" == "resource_request_update" ]]; then
            container=$(jq -r '.container // empty' <<< "$json_object")
            resource=$(jq -r '.resource // empty' <<< "$json_object")
            current_value=$(jq -r '.current_value // empty' <<< "$json_object")
            suggested_value=$(jq -r '.suggested_value // empty' <<< "$json_object")
            echo "Modifying $resource resource request for container \`$container\` in $object_type \`$object_name\` to \`$suggested_value\` in namespace \`$NAMESPACE\` based on VPA recommendation."
            substitutions_list[$object_id]+="$container,$resource,$current_value,$suggested_value;"
            substitution_function=resource_request_substitution
            change_summary+="[Change] Modifying $resource resource request for container \`$container\` in $object_type \`$object_name\` to \`$suggested_value\` in namespace \`$NAMESPACE\` based on VPA recommendation.<br>"
            change_details+="$json_pretty"
        elif [[ "$remediation_type" == "pvc_increase" ]]; then
            pvc_name=$(jq -r '.mongodata-users-mongo // empty' <<< "$json_object")
            pod=$(jq -r '.pod // empty' <<< "$json_object")
            usage=$(jq -r '.usage // empty' <<< "$json_object")
            current_size=$(jq -r '.current_size // empty' <<< "$json_object")
            recommended_size=$(jq -r '.recommended_size // empty' <<< "$json_object")
            echo "Increasing PersistentVolumeClaim $pvc_name with usage $usage from $current_size to $recommended_size"
            substitutions_list[$object_id]+="$pvc_name,$resource,$current_size,$recommended_size;"
            substitution_function=pvc_increase     
            change_summary+="[Change] Increasing PersistentVolumeClaim \`$pvc_name\` attached to \`$pod\` to \`$recommended_size\` in namespace \`$NAMESPACE\`.<br>"
            change_details+="$json_pretty"
        elif [[ "$remediation_type" == "probe_update" ]]; then
            probe_type=$(jq -r '.probe_type' <<< "$json_object")
            exec=$(jq -r '.exec' <<< "$json_object")
            invalid_command=$(jq -r '.invalid_command // empty' <<< "$json_object")
            valid_command=$(jq -r '.valid_command // empty' <<< "$json_object")
            invalid_ports=$(jq -r '.invalid_ports // empty' <<< "$json_object")
            valid_ports=$(jq -r '.valid_ports // empty' <<< "$json_object")
            container=$(jq -r '.container // empty' <<< "$json_object")
            if [[ "$exec" == "true" && -n "$invalid_command" ]]; then
                echo "Processing $object_type $object_name with invalidCommand"
                find_gitops_info "$object_type" "$object_name"
                old_string=$invalid_command
                new_string=$valid_command
                substitutions_list[$object_id]+="$container,$probe_type,$old_string,$new_string,$invalid_ports,$valid_ports;"
                substitution_function=probe_exec_substitution
                change_summary+="[Change] Container \`$container\` in $object_type \`$object_name\` had an invalid exec command for $probe_type. The updated command is \`$valid_command\`<br>"
                change_details+="$json_pretty"

            elif [[ "$exec" == "true" && -n "$invalid_ports" ]]; then
                echo "Processing $object_type $object_name with invalidPorts"
            fi
        fi
    done < <(echo -e "${change_list[$object_id]}")

    # Apply changes and create a single PR
    update_github_manifests
done


# Display all unique recommendations that can be shown as Next Steps
if [[ ${#next_steps[@]} -ne 0 ]]; then
    printf "\nRecommended Next Steps: \n"
    printf "%s\n" "${next_steps[@]}" | sort -u
fi
