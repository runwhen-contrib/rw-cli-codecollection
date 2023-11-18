#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script is designed to fetch information about containers  
# that are restarting in a namespace and provide helpful recommendations 
# based on the status messages provided by Kubernetes
# -----------------------------------------------------------------------------

# Update PATH to ensure script dependencies are found
export PATH="$PATH"

# -------------------------- Function Definitions -----------------------------

# Check if a command exists
function check_command_exists() {
    if ! command -v $1 &> /dev/null; then
        echo "$1 could not be found"
        exit
    fi
}

# Tasks to perform when container exit code is "Success"
function exit_code_success() {
    echo "The exit code returned was 'Success' for pod \`$1\`. This usually means that the container has successfully run to completion."
    echo "Checking which resources might be related to this pod..."
    owner=$(find_resource_owner "$1")
    owner_kind=$(echo $owner | jq -r '.kind')
    owner_name=$(echo $owner | jq -r '.metadata.name')
    labels_json=$(echo $owner | jq -r '.metadata.labels')
    flux_labels=$(find_matching_labels "$labels_json" "flux")
    argocd_labels=$(find_matching_labels "$labels_json" "argo")
    command_override_check=$(check_manifest_configuration "$owner_kind/$owner_name")
    if [[ "$command_override_check" ]]; then 
        echo "The command for \`$owner_kind/$owner_name\` has an explicit configuration. Please verify this is accurate: \`$command_override_check\`"
    fi
    echo "Detected that \`$owner_kind/$owner_name\` manages this pod. Checking for other controllers that might be related..."
    if [[ "$flux_labels" ]]; then
        echo "Detected FluxCD controlled resource."
        flux_labels=$(echo "$flux_labels" | tr ' ' '\n')
        namespace=$(echo "$flux_labels" | grep namespace: | awk -F ":" '{print $2}') 
        name=$(echo "$flux_labels" | grep name: | awk -F ":" '{print $2}')
        recommendations+=("Check that the FluxCD resources are not suspended and the manifests are accurate for app:\`$name\`, configured in GitOps namespace:\`$namespace\`") 
    elif [[ "$argocd_labels" ]]; then
        echo "Detected ArgoCD"
        argocd_labels=$(echo "$argocd_labels" | tr ' ' '\n')
        instance=$(echo "$argocd_labels" | grep instance: | awk -F ":" '{print $2}') 
        recommendations+=("Check that the ArgoCD resources and manifests are accurate for app instance \`$instance\`")
    else
      recommendations+=("Owner resources appear to be manually applied. Please review the manifest for \`$owner\` in \`$NAMESPACE\` for accuracy.")
    fi
}

function find_resource_owner(){
    pod_owner_kind=$(kubectl get pods $1 -o json --context=${CONTEXT} -n ${NAMESPACE}| jq -r '.metadata.ownerReferences[0].kind' )
    pod_owner_name=$(kubectl get pods $1 -o json --context=${CONTEXT} -n ${NAMESPACE}| jq -r '.metadata.ownerReferences[0].name' )
    resource_owner_kind=$(kubectl get $pod_owner_kind/$pod_owner_name -o json --context=${CONTEXT} -n ${NAMESPACE} | jq -r '.metadata.ownerReferences[0].kind' )
    resource_owner_name=$(kubectl get $pod_owner_kind/$pod_owner_name -o json --context=${CONTEXT} -n ${NAMESPACE} | jq -r '.metadata.ownerReferences[0].name' )
    owner=$(kubectl get $resource_owner_kind/$resource_owner_name -o json  --context=${CONTEXT} -n ${NAMESPACE})
    echo $owner
}

# Define a Bash function that returns matching labels
function find_matching_labels() {
    local labels_json="$1"
    local text_to_match="$2"
    local matching_labels=()

    # Use jq to filter and return key-value pairs where either the key or value contains the specified text
    matching_pairs=$(echo "$labels_json" | jq -r 'to_entries[] | select(.key | contains("'$text_to_match'")) | "\(.key):\(.value)"')

    # Check if the label key or value contains the specified text
    for label in $matching_pairs; do
        matching_labels+=("$label")
    done

    echo "${matching_labels[*]}"
}
function check_manifest_configuration() {
    resource="$1"
    command_override_check=$(kubectl get $1 --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r '
    .spec.template.spec.containers[] |
    select(.command != null) |
    "Container Name: \(.name)\nCommand: \(.command | join(" "))\nArguments: \(.args | join(" "))\n---"
    ')
    echo $command_override_check
}
# ------------------------- Dependency Verification ---------------------------

# Ensure all the required binaries are accessible
check_command_exists ${KUBERNETES_DISTRIBUTION_BINARY}
check_command_exists jq


EXIT_CODE_EXPLANATIONS='{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}'

container_restarts_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r --argjson exit_code_explanations "$EXIT_CODE_EXPLANATIONS" '
{
  "container_restarts": [
    .items[] | select(.status.containerStatuses != null) | select(any(.status.containerStatuses[]; .restartCount > 0)) | {
      pod_name: .metadata.name,
      containers: [
        .status.containerStatuses[] | {
          name: .name,
          restart_count: .restartCount,
          message: (.state.waiting.message // "N/A"),
          terminated_reason: (.lastState.terminated.reason // "N/A"),
          terminated_finishedAt: (.lastState.terminated.finishedAt // "N/A"),
          terminated_exitCode: (.lastState.terminated.exitCode // "N/A"),
          exit_code_explanation: ($exit_code_explanations[.lastState.terminated.exitCode | tostring] // "Unknown exit code")
        }
      ]
    }
  ]
}'
)

if [ "$(echo "$container_restarts_json" | jq '.container_restarts | length')" -eq 0 ]; then
    echo "No containers with restarts found."
    exit 0
fi

declare -A container_restarts_dict
container_restarts_dict=$(echo "$container_restarts_json" | jq -r '.container_restarts[] | {"item": .}' | jq -s add)


# Extract data and print in a clean text format
container_details_dict=()

containers=$(echo "$container_restarts_json" | jq -c '.container_restarts[]')

while read -r container; do
  pod_name=$(echo "$container" | jq -r '.pod_name')
  
  container_text="Pod Name: $pod_name\n"

  container_list=$(echo "$container" | jq -c '.containers[]')

  while read -r c; do
    name=$(echo "$c" | jq -r '.name')
    restart_count=$(echo "$c" | jq -r '.restart_count')
    message=$(echo "$c" | jq -r '.message')
    terminated_reason=$(echo "$c" | jq -r '.terminated_reason')
    terminated_finishedAt=$(echo "$c" | jq -r '.terminated_finishedAt')
    terminated_exitCode=$(echo "$c" | jq -r '.terminated_exitCode')
    exit_code_explanation=$(echo "$c" | jq -r '.exit_code_explanation')

    container_text+="Containers:\n"
    container_text+="Name: $name\n"
    container_text+="Restart Count: $restart_count\n"
    container_text+="Message: $message\n"
    container_text+="Terminated Reason: $terminated_reason\n"
    container_text+="Terminated FinishedAt: $terminated_finishedAt\n"
    container_text+="Terminated ExitCode: $terminated_exitCode\n"
    container_text+="Exit Code Explanation: $exit_code_explanation\n\n"

  done <<< "$container_list"

  container_details_dict+=("$container_text")
done <<< "$containers"


# Print the container restart details
printf "\nContainer Restart Details: \n"
for container_text in "${container_details_dict[@]}"; do
    echo -e "$container_text"
done

recommendations=()
printf "Container Restart Analysis: \n"
for item in "${container_restarts_dict[@]}"; do
    # Extract the exit code explanation from the container
    exit_code_explanation=$(jq -r '.item.containers[0].exit_code_explanation' <<< "$item")
    pod_name=$(jq -r .item.pod_name <<< "$item")
    owner=$(find_resource_owner "$pod_name")
    owner_kind=$(jq -r '.kind' <<< "$item")
    owner_name=$(jq -r '.metadata.name' <<< "$item")
    # Use a case statement to check the exit code and perform actions or recommendations
    case "$exit_code_explanation" in
        "Success")
            exit_code_success "$pod_name"
            ;;
        "Error")
            echo "Container exited with an error code."
            # Add your action for Error here
            recommendations+=("Check $owner_kind Log for Issues with \`$owner_name\`")
            ;;
        "Misconfiguration")
            echo "Container stopped due to misconfiguration"
            # Add your action for Misconfiguration here
            recommendations+=("Review $owner_kind \`$owner_name\` configuration for any mistakes. Ensure environment variables, volume mounts, and resource limits are correctly set.")
            ;;
        "Pod terminated by SIGINT")
            echo "Container received SIGINT signal, indicating an interrupted process."
            # Add your action for SIGINT here
            recommendations+=("Check $owner_kind Event Anomalies for \`$owner_name\`")
            recommendations+=("If SIGINT is frequently occuring, escalate to the service or infrastructure owner for further investigation.")
            ;;
        "Abnormal Termination SIGABRT")
            echo "Container terminated abnormally with SIGABRT signal."
            # Add your action for SIGABRT here
            recommendations+=("Check $owner_kind Log for Issues with \`$owner_name\`")
            recommendations+=("SIGABRT is usually a serious error. If it doesn't appear application related, escalate to the service or infrastructure owner for further investigation.")
            ;;
        "Pod terminated by SIGKILL - Possible OOM")
            echo "Container terminated by SIGKILL, possibly due to Out Of Memory. Check if the container exceeded its memory limit. Consider increasing memory allocation or optimizing the application for better memory usage."
            # Add your action for SIGKILL - Possible OOM here
            recommendations+=("Check $owner_kind Log for Issues with \`$owner_name\`")
            recommendations+=("Get Pod Resource Utilization with Top in Namespace \`$NAMESPACE\`")
            recommendations+=("Show Pods Without Resource Limit or Resource Requests Set in Namespace \`$NAMESPACE\`")
            ;;
        "Graceful Termination SIGTERM")
            echo "Container received SIGTERM signal for graceful termination.Ensure that the container's shutdown process is handling SIGTERM correctly. This may be a normal part of the pod lifecycle."
            # Add your action for SIGTERM here
            recommendations+=("If SIGTERM is frequently occuring, escalate to the service or infrastructure owner for further investigation.")
            ;;
        *)
            echo "Unknown exit code for pod \`$pod_name\`: $exit_code_explanation"
            echo "$item"
            # Handle unknown exit codes here
            recommendations+=("Unknown exit code for pod \`$pod_name\`. Escalate to the service or infrastructure owner for further investigation.")
            ;;
    esac
done

# Display all unique recommendations that can be shown as Next Steps
if [[ ${#recommendations[@]} -ne 0 ]]; then
    printf "\nRecommended Next Steps: \n"
    printf "%s\n" "${recommendations[@]}" | sort -u
fi