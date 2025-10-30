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

# Analyze the actual cause of SIGKILL (exit code 137) to distinguish between OOM and liveness probe failures
function analyze_sigkill_cause() {
    local pod_name="$1"
    local container_name="$2"
    local terminated_time="$3"
    
    # Get pod events around the termination time
    local events=$(${KUBERNETES_DISTRIBUTION_BINARY} get events --context=${CONTEXT} -n ${NAMESPACE} --field-selector involvedObject.name=${pod_name} -o json 2>/dev/null)
    
    # Get container status details
    local pod_status=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod ${pod_name} --context=${CONTEXT} -n ${NAMESPACE} -o json 2>/dev/null)
    local terminated_reason=$(echo "$pod_status" | jq -r ".status.containerStatuses[] | select(.name==\"$container_name\") | .lastState.terminated.reason // \"N/A\"")
    
    # STEP 1: Check for EXPLICIT OOMKilled reason (most reliable)
    if [[ "$terminated_reason" == "OOMKilled" ]]; then
        return 1  # Confirmed OOM
    fi
    
    # STEP 2: Look for EXPLICIT OOM-related events (second most reliable)
    local oom_events=$(echo "$events" | jq -r '.items[] | select(.reason == "OOMKilling" or (.reason == "Killing" and (.message | contains("Memory cgroup out of memory"))) or (.message | contains("oom-kill")) or (.message | contains("Out of memory")) or (.message | contains("memory limit exceeded"))) | .message' 2>/dev/null)
    
    if [[ -n "$oom_events" ]]; then
        return 1  # OOM confirmed via events
    fi
    
    # STEP 3: Look for EXPLICIT liveness probe failure events (high confidence)
    local probe_events=$(echo "$events" | jq -r '.items[] | select((.reason == "Unhealthy" and (.message | contains("Liveness probe failed"))) or (.reason == "Killing" and (.message | contains("liveness probe failed"))) or (.reason == "FailedMount" and (.message | contains("probe")))) | .message' 2>/dev/null)
    
    if [[ -n "$probe_events" ]]; then
        return 2  # Liveness probe failure confirmed
    fi
    
    # STEP 4: Check for resource pressure or node-level issues
    local node_events=$(${KUBERNETES_DISTRIBUTION_BINARY} get events --context=${CONTEXT} --all-namespaces --field-selector reason=NodeHasDiskPressure,reason=NodeHasMemoryPressure,reason=NodeHasPIDPressure -o json 2>/dev/null)
    local pressure_events=$(echo "$node_events" | jq -r '.items[] | select(.lastTimestamp >= "'$(date -d '10 minutes ago' -Iseconds)'" or .firstTimestamp >= "'$(date -d '10 minutes ago' -Iseconds)'") | .message' 2>/dev/null)
    
    if [[ -n "$pressure_events" ]]; then
        return 3  # Node resource pressure
    fi
    
    # STEP 5: Look for system-level termination events
    local system_events=$(echo "$events" | jq -r '.items[] | select(.reason == "Killing" and ((.message | contains("preempt")) or (.message | contains("evict")) or (.message | contains("resource pressure")) or (.message | contains("node shutdown")))) | .message' 2>/dev/null)
    
    if [[ -n "$system_events" ]]; then
        return 3  # System-level termination
    fi
    
    # STEP 6: Analyze the terminated reason more carefully
    case "$terminated_reason" in
        "Error")
            # "Error" reason with exit 137 is often liveness probe failure, NOT OOM
            # Check if there are any health-related events
            local health_events=$(echo "$events" | jq -r '.items[] | select((.message | contains("health")) or (.message | contains("ready")) or (.message | contains("probe")) or (.message | contains("timeout"))) | .message' 2>/dev/null)
            
            if [[ -n "$health_events" ]]; then
                return 2  # Likely probe-related
            fi
            
            # Check for any "Killing" events without specific OOM indicators
            local general_killing=$(echo "$events" | jq -r '.items[] | select(.reason == "Killing") | .message' 2>/dev/null)
            
            if [[ -n "$general_killing" ]]; then
                # If killing events exist but no OOM evidence, likely probe failure
                return 2  # Likely probe failure
            fi
            ;;
        "Completed")
            return 4  # Normal completion, not an error
            ;;
        *)
            # Other reasons - analyze context
            ;;
    esac
    
    # STEP 7: Final analysis - if we have high restart count but no clear OOM evidence, likely probe issues
    local restart_count=$(echo "$pod_status" | jq -r ".status.containerStatuses[] | select(.name==\"$container_name\") | .restartCount // 0")
    
    if [[ $restart_count -gt 5 ]] && [[ "$terminated_reason" == "Error" ]]; then
        # High restart count with "Error" reason but no OOM evidence suggests probe failures
        return 2  # Likely probe failure pattern
    fi
    
    # If we can't determine the specific cause with confidence, return unknown
    return 0  # Unknown cause - requires investigation
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
                    # Analyze the actual cause of SIGKILL (exit 137)
                    analyze_sigkill_cause "$pod_name" "$name" "$terminated_finishedAt"
                    sigkill_cause=$?
                    
                    case $sigkill_cause in
                        1) # OOM Kill confirmed
                            echo "Container terminated by SIGKILL due to Out Of Memory (OOM) for pod \`$pod_name\`. Container exceeded memory limits."
                            issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts due to OOM in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nGet Pod Resource Utilization with Top in Namespace \`$NAMESPACE\`\\nShow Pods Without Resource Limit or Resource Requests Set in Namespace \`$NAMESPACE\`\\nIdentify Resource Constrained Pods In Namespace \`$NAMESPACE\`\\nCheck Node Resource Utilization and Capacity\",\"details\":\"Container terminated by SIGKILL due to confirmed OOM kill. Pod: $pod_name, Container: $name. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE. Root cause: CONFIRMED OOM KILL - container exceeded memory limits.\"}"
                            ;;
                        2) # Liveness Probe Failure confirmed
                            echo "Container terminated by SIGKILL due to liveness probe failure for pod \`$pod_name\`. Application failed health checks."
                            issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts due to liveness probe failures in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nCheck Liveliness Probe Configuration for $owner_kind \`$owner_name\`\\nGet Pod Resource Utilization with Top in Namespace \`$NAMESPACE\`\\nReview Application Health Check Endpoints\",\"details\":\"Container terminated by SIGKILL due to liveness probe failure. Pod: $pod_name, Container: $name. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE. Root cause: LIVENESS PROBE FAILURE - application was unresponsive to health checks, NOT an OOM issue.\"}"
                            ;;
                        3) # Other SIGKILL cause (preemption, etc.)
                            echo "Container terminated by SIGKILL due to system-level termination for pod \`$pod_name\` (preemption, eviction, or resource pressure)."
                            issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` has container restarts due to system termination in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nInspect $owner_kind Warning Events for \`$owner_name\`\\nCheck Node Resource Utilization and Capacity\\nReview Pod Priority Classes and Resource Requests\",\"details\":\"Container terminated by SIGKILL due to system-level events. Pod: $pod_name, Container: $name. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE. Root cause: SYSTEM-LEVEL TERMINATION - pod preemption, node resource pressure, or cluster scheduling decisions.\"}"
                            ;;
                        *) # Unknown/unclear cause
                            echo "Container terminated by SIGKILL for pod \`$pod_name\` - cause unclear. Requires investigation to determine if OOM, probe failure, or other issue."
                            issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has container restarts due to unclear SIGKILL cause in namespace \`${NAMESPACE}\` in the last $CONTAINER_RESTART_AGE\",\"next_steps\":\"Check $owner_kind Log for Issues with \`$owner_name\`\\nInspect $owner_kind Warning Events for \`$owner_name\`\\nGet Pod Resource Utilization with Top in Namespace \`$NAMESPACE\`\\nCheck Liveliness Probe Configuration for $owner_kind \`$owner_name\`\",\"details\":\"Container terminated by SIGKILL with unclear cause. Pod: $pod_name, Container: $name. Total restart count: $restart_count (lifetime total). Most recent restart occurred within the last $CONTAINER_RESTART_AGE. Root cause: REQUIRES INVESTIGATION - could be OOM, liveness probe failure, or other system-level termination.\"}"
                            ;;
                    esac
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
        
        issue_details="$(printf '%s' "$issue_details" | jq --arg ts "$terminated_finishedAt" '. + {observed_at: $ts}')"
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
