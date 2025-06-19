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

# Tasks to perform when container exit code is "Error" or 1
function exit_code_error() {
    logs=$(${KUBERNETES_DISTRIBUTION_BINARY} logs -p $1  --all-containers --context=${CONTEXT} -n ${NAMESPACE} )
    escaped_log_data=$(echo "$logs" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

    echo $escaped_log_data
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
        issue_details="{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Check that the FluxCD resources are not suspended and the manifests are accurate for app:\`$name\`, configured in GitOps namespace:\`$namespace\`\",\"details\":\"The exit code returned was 'Success' for pod \`$1\`. This usually means that the container has successfully run to completion.\"}"
    elif [[ "$argocd_labels" ]]; then
        echo "Detected ArgoCD"
        argocd_labels=$(echo "$argocd_labels" | tr ' ' '\n')
        instance=$(echo "$argocd_labels" | grep instance: | awk -F ":" '{print $2}')
        issue_details="{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Check that the ArgoCD resources and manifests are accurate for app instance \`$instance\`\",\"details\":\"The exit code returned was 'Success' for pod \`$1\`. This usually means that the container has successfully run to completion.\"}"
    else
        issue_details="{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Owner resources appear to be manually applied. Please review the manifest for \`$owner\` in \`$NAMESPACE\` for accuracy.\",\"details\":\"The exit code returned was 'Success' for pod \`$1\`. This usually means that the container has successfully run to completion.\"}"
    fi
}

function find_resource_owner(){
    pod=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $1 --context=${CONTEXT} -n ${NAMESPACE} -o json )
    pod_owner_kind=$(echo $pod | jq -r '.metadata.ownerReferences[0].kind' )
    pod_owner_name=$(echo $pod | jq -r '.metadata.ownerReferences[0].name' )
    resource_owner=$(${KUBERNETES_DISTRIBUTION_BINARY} get $pod_owner_kind/$pod_owner_name --context=${CONTEXT} -n ${NAMESPACE} -o json)
    resource_owner_kind=$(echo $resource_owner | jq -r '.metadata.ownerReferences[0].kind' )
    resource_owner_name=$(echo $resource_owner | jq -r '.metadata.ownerReferences[0].name' )
    owner=$(${KUBERNETES_DISTRIBUTION_BINARY} get $resource_owner_kind/$resource_owner_name --context=${CONTEXT} -n ${NAMESPACE} -o json)
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
    command_override_check=$(${KUBERNETES_DISTRIBUTION_BINARY} get $1 --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r '
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

# Set default values for time-based filtering if not provided
CONTAINER_RESTART_AGE=${CONTAINER_RESTART_AGE:-"1h"}
CONTAINER_RESTART_THRESHOLD=${CONTAINER_RESTART_THRESHOLD:-"1"}

# Calculate threshold time for filtering container restarts
TIME_PERIOD="${CONTAINER_RESTART_AGE}"
TIME_PERIOD_UNIT=$(echo $TIME_PERIOD | awk '{print substr($0,length($0),1)}')
TIME_PERIOD_VALUE=$(echo $TIME_PERIOD | awk '{print substr($0,1,length($0)-1)}')

if [[ $TIME_PERIOD_UNIT == "m" ]]; then
    DATE_CMD_ARG="$TIME_PERIOD_VALUE minutes ago"
elif [[ $TIME_PERIOD_UNIT == "h" ]]; then
    DATE_CMD_ARG="$TIME_PERIOD_VALUE hours ago"
else
    echo "Unsupported time period unit. Use 'm' for minutes or 'h' for hours."
    exit 1
fi

THRESHOLD_TIME=$(date -u --date="$DATE_CMD_ARG" +"%Y-%m-%dT%H:%M:%SZ")

EXIT_CODE_EXPLANATIONS='{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}'

# Fetch the label selector from the deployment
DEPLOYMENT_LABEL_SELECTOR=$(${KUBERNETES_DISTRIBUTION_BINARY} get deployment ${DEPLOYMENT_NAME} --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')

# Fetch pods related to the specified deployment using the label selector
pods_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} -l ${DEPLOYMENT_LABEL_SELECTOR} -o json)

# Modified query to include time-based filtering and select containers with restarts
container_restarts_json=$(echo "$pods_json" | jq -r --argjson exit_code_explanations "$EXIT_CODE_EXPLANATIONS" --arg threshold_time "$THRESHOLD_TIME" '
{
  "container_restarts": [
    .items[] | select(.status.containerStatuses != null) | 
    select(any(.status.containerStatuses[]; .restartCount > 0 and (.lastState.terminated.finishedAt // "1970-01-01T00:00:00Z") > $threshold_time)) | {
      pod_name: .metadata.name,
      containers: [
        .status.containerStatuses[] | select(.restartCount > 0 and (.lastState.terminated.finishedAt // "1970-01-01T00:00:00Z") > $threshold_time) | {
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
    echo "No containers with restarts found for deployment ${DEPLOYMENT_NAME} in the last ${CONTAINER_RESTART_AGE}."
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
    # Find the container with the highest restart count for issue details
    exit_code_explanation=$(jq -r '.item.containers | sort_by(.restart_count) | reverse | .[0].exit_code_explanation' <<< "$item")
    message=$(jq -r '.item.containers | sort_by(.restart_count) | reverse | .[0].message' <<< "$item")
    pod_name=$(jq -r .item.pod_name <<< "$item")
    container_name=$(jq -r '.item.containers | sort_by(.restart_count) | reverse | .[0].name' <<< "$item")
    restart_count=$(jq -r '.item.containers | sort_by(.restart_count) | reverse | .[0].restart_count' <<< "$item")
    
    # Only create issues if restart count exceeds threshold
    if [ "$restart_count" -gt "$CONTAINER_RESTART_THRESHOLD" ]; then
        owner=$(find_resource_owner "$pod_name")
        owner_kind=$(jq -r '.kind' <<< "$owner")
        owner_name=$(jq -r '.metadata.name' <<< "$owner")
        
        # Use a case statement to check the exit code and perform actions or recommendations
        case "$exit_code_explanation" in
            "Success")
                exit_code_success "$pod_name"
                ;;
            "Error")
                echo "Container exited with an error code."
                details=$(exit_code_error "$pod_name")
                issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nView issue details in report for container log details\",\"details\":\"Container \`$container_name\` exited with an error code. Log Details: \\n$details\"}"
                ;;
            "Misconfiguration")
                echo "Container stopped due to misconfiguration"
                issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Get $owner_kind \`$owner_name\` manifest and check configuration for any mistakes.\",\"details\":\"Container \`$container_name\` stopped due to misconfiguration\"}"
                ;;
            "Pod terminated by SIGINT")
                echo "Container received SIGINT signal, indicating an interrupted process."
                issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Check $owner_kind Event Anomalies for \`$owner_name\`\\nIf SIGINT is frequently occuring, escalate to the service or infrastructure owner for further investigation.\",\"details\":\"Container \`$container_name\` received SIGINT signal, indicating an interrupted process.\"}"
                ;;
            "Abnormal Termination SIGABRT")
                echo "Container terminated abnormally with SIGABRT signal."
                issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nSIGABRT is usually a serious error. If it doesn't appear application related, escalate to the service or infrastructure owner for further investigation.\",\"details\":\"Container \`$container_name\` terminated abnormally with SIGABRT signal.\"}"
                ;;
            "Pod terminated by SIGKILL - Possible OOM")
                if [[ $message =~ "Pod was terminated in response to imminent node shutdown." ]]; then
                    echo "Container terminated by SIGKILL related to node shutdown."
                    issue_details="{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` in namespace \`${NAMESPACE}\` was evicted due to node shutdown\",\"next_steps\":\"Inspect $owner_kind replicas for \`$owner_name\`\"}"
                else
                    echo "Container terminated by SIGKILL, possibly due to Out Of Memory. Check if the container exceeded its memory limit. Consider increasing memory allocation or optimizing the application for better memory usage."
                    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nGet Pod Resource Utilization with Top in Namespace \`$NAMESPACE\`\\nShow Pods Without Resource Limit or Resource Requests Set in Namespace \`$NAMESPACE\`\\nIdentify Resource Constrained Pods In Namespace \`$NAMESPACE\`\",\"details\":\"Container \`$container_name\` terminated by SIGKILL, possibly due to Out Of Memory. Check if the container exceeded its memory limit. Consider increasing memory allocation or optimizing the application for better memory usage.\"}"
                fi
                ;;
            "Graceful Termination SIGTERM")
                echo "Container received SIGTERM signal for graceful termination.Ensure that the container's shutdown process is handling SIGTERM correctly. This may be a normal part of the pod lifecycle."
                issue_details="{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"If SIGTERM is frequently occuring, escalate to the service or infrastructure owner for further investigation.\",\"details\":\"Container \`$container_name\` received SIGTERM signal for graceful termination.Ensure that the container's shutdown process is handling SIGTERM correctly. This may be a normal part of the pod lifecycle.\"}"
                ;;
            *)
                echo "Unknown exit code for pod \`$pod_name\`: $exit_code_explanation"
                echo "$item"
                # Handle unknown exit codes here
                issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"Unknown exit code for pod \`$pod_name\`. Escalate to the service or infrastructure owner for further investigation.\",\"details\":\"Unknown exit code for pod \`$pod_name\` container \`$container_name\`: $exit_code_explanation\"}"
                ;;
        esac
        
        # Initialize issues as an empty array if not already set
        if [ -z "$issues" ]; then
            issues="[]"
        fi

        # Concatenate issue detail to the string
        if [ -n "$issue_details" ]; then
            # Remove the closing bracket from issues to prepare for adding a new item
            issues="${issues%]}"

            # If issues is not an empty array (more than just "["), add a comma before the new item
            if [ "$issues" != "[" ]; then
                issues="$issues,"
            fi

            # Add the new issue detail and close the array
            issues="$issues $issue_details]"
        fi
    fi
done

# Display all unique recommendations that can be shown as Next Steps
if [ -n "$issues" ]; then
    echo -e "\nRecommended Next Steps: \n"
    echo "$issues"
fi
