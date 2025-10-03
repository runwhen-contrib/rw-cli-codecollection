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
    logs=$(${KUBERNETES_DISTRIBUTION_BINARY} logs -p $1 -c $2 --tail=50 --context=${CONTEXT} -n ${NAMESPACE})
    if [ -z "$logs" ]; then
        logs="Previous container logs could not be found."
    else
        logs=$(echo "$logs" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed 's/\x00-\x1F/\\u&/g' | sed ':a;N;$!ba;s/\n/\\n/g')

    fi
    echo "$logs"
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
    pod_owner_kind=$(echo $pod |  jq -r '.metadata.ownerReferences[0].kind' )
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

# Function to convert time duration (e.g., 24h or 30m) to seconds
function duration_to_seconds() {
    local duration=$1
    local seconds=0

    if [[ $duration =~ ^([0-9]+)h$ ]]; then
        seconds=$((BASH_REMATCH[1] * 3600))
    elif [[ $duration =~ ^([0-9]+)m$ ]]; then
        seconds=$((BASH_REMATCH[1] * 60))
    else
        echo "Invalid duration format. Please use format like 24h or 30m."
        exit 1
    fi

    echo $seconds
}

# Get the current time in seconds since epoch
current_time=$(date +%s)

# Specify the time window for considering restarts (e.g., "24h" for 24 hours or "30m" for 30 minutes)
time_window=$CONTAINER_RESTART_AGE
time_window_seconds=$(duration_to_seconds $time_window)

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

# Extract data and print in a clean text format
container_details_dict=()
recommendations=()

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

    if [ "$exit_code_explanation" != "Unknown exit code" ] && [ "$terminated_exitCode" != "N/A" ]; then
      # Calculate the age of the restart
      terminated_time=$(date -d "$terminated_finishedAt" +%s)
      restart_age=$((current_time - terminated_time))

      # Filter out restarts older than the specified time window
      if [ $restart_age -le $time_window_seconds ]; then
        container_text+="Containers:\n"
        container_text+="Name: $name\n"
        container_text+="Total Restart Count: $restart_count (lifetime total)\n"
        container_text+="Message: $message\n"
        container_text+="Terminated Reason: $terminated_reason\n"
        container_text+="Terminated FinishedAt: $terminated_finishedAt\n"
        container_text+="Terminated ExitCode: $terminated_exitCode\n"
        container_text+="Exit Code Explanation: $exit_code_explanation\n"
        container_text+="Note: Most recent restart occurred within the last $CONTAINER_RESTART_AGE\n\n"

        owner=$(find_resource_owner "$pod_name")
        owner_kind=$(jq -r '.kind' <<< "$owner")
        owner_name=$(jq -r '.metadata.name' <<< "$owner")

        # Use a case statement to check the exit code and perform actions or recommendations
        case "$exit_code_explanation" in
            "Success")
                exit_code_success "$pod_name"
                ;;
            "Error")
                echo "Container exited with an error code for pod \`$pod_name\`."
                details=$(exit_code_error "$pod_name" "$name")
                issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nView issue details in report for container log details\",\"details\":\"Container exited with an error code. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE. Log Details: \\n$details\"}"
                ;;
            "Misconfiguration")
                echo "Container stopped due to misconfiguration for pod \`$pod_name\`"
                
                issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Get $owner_kind \`$owner_name\` manifest and check configuration for any mistakes.\",\"details\":\"Container stopped due to misconfiguration. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE.\"}"
                ;;
            "Pod terminated by SIGINT")
                echo "Container received SIGINT signal, indicating an interrupted process for pod \`$pod_name\`."
                issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Check $owner_kind Event Anomalies for \`$owner_name\`\\nIf SIGINT is frequently occuring, escalate to the service or infrastructure owner for further investigation.\",\"details\":\"Container received SIGINT signal, indicating an interrupted process. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE.\"}"           
                ;;
            "Abnormal Termination SIGABRT")
                echo "Container terminated abnormally with SIGABRT signal for pod \`$pod_name\`."
                issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nSIGABRT is usually a serious error. If it doesn't appear application related, escalate to the service or infrastructure owner for further investigation.\",\"details\":\"Container terminated abnormally with SIGABRT signal. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE.\"}"           
                ;;
            "Pod terminated by SIGKILL - Possible OOM")
                if [[ $message =~ "Pod was terminated in response to imminent node shutdown." ]]; then
                    echo "Container terminated by SIGKILL related to node shutdown for pod \`$pod_name\`."
                    issue_details="{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` in namespace \`${NAMESPACE}\` was evicted due to node shutdown in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Inspect $owner_kind replicas for \`$owner_name\`\",\"details\":\"Container terminated by SIGKILL related to node shutdown. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE.\"}"
                else
                    echo "Container terminated by SIGKILL, possibly due to Out Of Memory, for pod \`$pod_name\`. Check if the container exceeded its memory limit. Consider increasing memory allocation or optimizing the application for better memory usage."
                    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nGet Pod Resource Utilization with Top in Namespace \`$NAMESPACE\`\\nShow Pods Without Resource Limit or Resource Requests Set in Namespace \`$NAMESPACE\`\\nIdentify Resource Constrained Pods In Namespace \`$NAMESPACE\`\",\"details\":\"Container terminated by SIGKILL, possibly due to Out Of Memory. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE. Check if the container exceeded its memory limit. Consider increasing memory allocation or optimizing the application for better memory usage.\"}"
                fi
                ;;
            "Graceful Termination SIGTERM")
                echo "Container received SIGTERM signal for graceful termination for pod \`$pod_name\` in the last $CONTAINER_RESTART_AGE. Ensure that the container's shutdown process is handling SIGTERM correctly. This may be a normal part of the pod lifecycle."
                issue_details="{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\`\",\"next_steps\":\"If SIGTERM is frequently occuring, escalate to the service or infrastructure owner for further investigation.\",\"details\":\"Container received SIGTERM signal for graceful termination. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE. Ensure that the container's shutdown process is handling SIGTERM correctly. This may be a normal part of the pod lifecycle.\"}"
                ;;
            *)
                echo "Unknown exit code for pod \`$pod_name\`: $exit_code_explanation"
                echo "$item"
                # Handle unknown exit codes here
                issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` has container restarts in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Unknown exit code for pod \`$pod_name\`. Escalate to the service or infrastructure owner for further investigation.\",\"details\":\"Unknown exit code for pod \`$pod_name\`: $exit_code_explanation. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE.\"}"
                ;;
        esac

        # Add issue detail to the list of recommendations
        recommendations+=("$issue_details")
      fi

    fi

  done <<< "$container_list"

  container_details_dict+=("$container_text")
done <<< "$containers"

# Print the container restart details
printf "\nContainer Restart Details: \n"
for container_text in "${container_details_dict[@]}"; do
    echo -e "$container_text"
done

# Convert the recommendations array to a valid JSON list and remove duplicates
recommendations_json=$(printf '%s\n' "${recommendations[@]}" | jq -s 'unique_by(.title)')

# Display all unique recommendations that can be shown as Next Steps
if [ -n "$recommendations_json" ]; then
    echo -e "\nRecommended Next Steps: \n"
    echo "$recommendations_json"
    echo "$recommendations_json" > container_restart_issues.json
fi
