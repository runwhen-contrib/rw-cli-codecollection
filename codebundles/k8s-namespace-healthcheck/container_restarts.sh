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
    echo "The exit code returned was 'Success' for pod $1. This usually means that the container has successfully run to completion... "
    owner=$(find_resource_owner $1)
    labels_json=$(echo $owner | jq -r '.metadata.labels')
    flux_labels=$(find_matching_labels "$labels_json" "flux")
    argocd_labels=$(find_matching_labels "$labels_json" "argo")
    if [[ "$flux_labels" ]]; then
        echo "Detected FluxCD controlled resource..."
        flux_labels=$(echo "$flux_labels" | tr ' ' '\n')
        namespace=$(echo "$flux_labels" | grep namespace: | awk -F ":" '{print $2}') 
        name=$(echo "$flux_labels" | grep name: | awk -F ":" '{print $2}')
        recommendations+=("Check that the FluxCD resources are not suspended and the manifests are accurate for app $name, configured in GitOps namespace $namespace")  
    elif [[ "$argocd_labels" ]]; then
        echo "Detected ArgoCD"
        argocd_labels=$(echo "$argocd_labels" | tr ' ' '\n')
        instance=$(echo "$argocd_labels" | grep instance: | awk -F ":" '{print $2}') 
        recommendations+=("Check that the ArgoCD resources and manifests are accurate for app instance $instance")
    else
      recommendations+=("Owner resources appear to be manually applied. Please review the manifest for $owner in $NAMESPACE for accuracy.")
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

declare -A container_restarts_dict
container_restarts_dict=$(echo "$container_restarts_json" | jq -r '.container_restarts[] | {"item": .}' | jq -s add)

printf "\nContainer Restart Details: \n"
for container in "${container_restarts_dict[@]}"; do
    echo "$container"
done

recommendations=()
printf "Container Restart Analysis: \n"
for item in "${container_restarts_dict[@]}"; do
    # Extract the exit code explanation from the container
    exit_code_explanation=$(jq -r '.item.containers[0].exit_code_explanation' <<< "$item")

    # Use a case statement to check the exit code and perform actions or recommendations
    case "$exit_code_explanation" in
        "Success")
            exit_code_success $(echo "$item" | jq -r .item.pod_name)
            ;;
        "Error")
            echo "Recommendation for Error: Do something for Error exit code"
            # Add your action for Error here
            ;;
        "Misconfiguration")
            echo "Recommendation for Misconfiguration: Do something for Misconfiguration exit code"
            # Add your action for Misconfiguration here
            ;;
        "Pod terminated by SIGINT")
            echo "Recommendation for SIGINT: Do something for SIGINT exit code"
            # Add your action for SIGINT here
            ;;
        "Abnormal Termination SIGABRT")
            echo "Recommendation for SIGABRT: Do something for SIGABRT exit code"
            # Add your action for SIGABRT here
            ;;
        "Pod terminated by SIGKILL - Possible OOM")
            echo "Recommendation for SIGKILL - Possible OOM: Do something for SIGKILL - Possible OOM exit code"
            # Add your action for SIGKILL - Possible OOM here
            ;;
        "Graceful Termination SIGTERM")
            echo "Recommendation for SIGTERM: Do something for SIGTERM exit code"
            # Add your action for SIGTERM here
            ;;
        *)
            echo "Unknown exit code: $exit_code_explanation"
            # Handle unknown exit codes here
            ;;
    esac
done

# Display all unique recommendations that can be shown as Next Steps
if [[ ${#recommendations[@]} -ne 0 ]]; then
    printf "\nRecommended Next Steps: \n"
    printf "%s\n" "${recommendations[@]}" | sort -u
fi