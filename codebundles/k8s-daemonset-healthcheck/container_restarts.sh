#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script is designed to fetch information about containers  
# that are restarting in a DaemonSet and provide helpful recommendations 
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
    logs=$(${KUBERNETES_DISTRIBUTION_BINARY} logs -p $1  --all-containers --context=${CONTEXT} -n ${NAMESPACE} )
    escaped_log_data=$(echo "$logs" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')

    echo $escaped_log_data
}

# Tasks to perform when container exit code is "Success"
function exit_code_success() {
    echo "The exit code returned was 'Success' for pod \`$1\`. This usually means that the container has successfully run to completion."
    echo "Checking which resources might be related to this pod..."
}

# Function to find the resource owner of a pod
function find_resource_owner() {
    pod_name="$1"
    owner=$(${KUBERNETES_DISTRIBUTION_BINARY} get pod $pod_name --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r '
    if .metadata.ownerReferences then
        .metadata.ownerReferences[0] as $owner |
        if $owner.kind == "ReplicaSet" then
            # If owned by ReplicaSet, find the Deployment that owns the ReplicaSet
            ($owner.name | split("-")[:-1] | join("-")) as $deployment_name |
            {
                "kind": "DaemonSet",
                "metadata": {
                    "name": $deployment_name
                }
            }
        else
            # Return the direct owner
            {
                "kind": $owner.kind,
                "metadata": {
                    "name": $owner.name
                }
            }
        end
    else
        # No owner reference, return the pod itself
        {
            "kind": "Pod",
            "metadata": {
                "name": .metadata.name
            }
        }
    end
    ')
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

# Set restart age threshold
THRESHOLD_TIME=$(date -d "${CONTAINER_RESTART_AGE} ago" --utc +"%Y-%m-%dT%H:%M:%SZ")

EXIT_CODE_EXPLANATIONS='{"0": "Success", "1": "Error", "2": "Misconfiguration", "130": "Pod terminated by SIGINT", "134": "Abnormal Termination SIGABRT", "137": "Pod terminated by SIGKILL - Possible OOM", "143":"Graceful Termination SIGTERM"}'

# Fetch the label selector from the DaemonSet
DAEMONSET_LABEL_SELECTOR=$(${KUBERNETES_DISTRIBUTION_BINARY} get daemonset ${DAEMONSET_NAME} --context=${CONTEXT} -n ${NAMESPACE} -o json | jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")')

# Fetch pods related to the specified DaemonSet using the label selector
pods_json=$(${KUBERNETES_DISTRIBUTION_BINARY} get pods --context=${CONTEXT} -n ${NAMESPACE} -l ${DAEMONSET_LABEL_SELECTOR} -o json)

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
    echo "No containers with restarts found for DaemonSet ${DAEMONSET_NAME} in the last ${CONTAINER_RESTART_AGE}."
    exit 0
fi

declare -A container_restarts_dict
issues=""

containers=$(echo "$container_restarts_json" | jq -c '.container_restarts[]')

while read -r container; do
    pod_name=$(echo "$container" | jq -r '.pod_name')
    
    container_list=$(echo "$container" | jq -c '.containers[]')
    
    while read -r c; do
        container_name=$(echo "$c" | jq -r '.name')
        restart_count=$(echo "$c" | jq -r '.restart_count')
        message=$(echo "$c" | jq -r '.message')
        terminated_reason=$(echo "$c" | jq -r '.terminated_reason')
        terminated_finishedAt=$(echo "$c" | jq -r '.terminated_finishedAt')
        terminated_exitCode=$(echo "$c" | jq -r '.terminated_exitCode')
        exit_code_explanation=$(echo "$c" | jq -r '.exit_code_explanation')
        
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
                    detailed_info="**Container Restart Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE (most recent restart within this timeframe)\\n\\n**Analysis:** Container exited with an error code indicating application or configuration issues.\\n\\n**Log Details:**\\n$details"
                    error_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nGet Container Resource Utilization for \`$container_name\` in Pod \`$pod_name\`\\nReview Application Configuration and Environment Variables\\nCheck Container Health Probes and Startup Sequence\\nVerify DaemonSet node-specific resource access"
                    issue_details="{\"severity\":\"2\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to errors in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$error_next_steps\",\"details\":\"$detailed_info\"}"
                    ;;
                "Misconfiguration")
                    echo "Container exited due to misconfiguration."
                    detailed_info="**Container Restart Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE (most recent restart within this timeframe)\\n\\n**Analysis:** Container exited due to misconfiguration. This typically indicates issues with environment variables, configuration files, or application settings."
                    misconfig_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nReview DaemonSet Configuration and Environment Variables\\nVerify ConfigMap and Secret Mounts\\nCheck DaemonSet Volume Mounts and Host Path Access\\nValidate Application Configuration Files\\nVerify Node-specific Resource Access"
                    issue_details="{\"severity\":\"2\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to misconfiguration in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$misconfig_next_steps\",\"details\":\"$detailed_info\"}"
                    ;;
                "Pod terminated by SIGINT")
                    echo "Container received SIGINT signal for interruption."
                    detailed_info="**Container Restart Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode (SIGINT)\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE (most recent restart within this timeframe)\\n\\n**Analysis:** Container received SIGINT signal for interruption. This usually indicates manual termination or controlled shutdown."
                    sigint_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nReview DaemonSet Update and Rollout History\\nCheck for Manual Pod Terminations\\nVerify DaemonSet Node Maintenance Operations"
                    issue_details="{\"severity\":\"4\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to SIGINT in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$sigint_next_steps\",\"details\":\"$detailed_info\"}"
                    ;;
                "Abnormal Termination SIGABRT")
                    echo "Container terminated abnormally with SIGABRT signal."
                    detailed_info="**Container Restart Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode (SIGABRT)\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE (most recent restart within this timeframe)\\n\\n**Analysis:** Container terminated abnormally with SIGABRT signal. This usually indicates a serious application error, assertion failure, or critical system issue."
                    sigabrt_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nGet Container Resource Utilization for \`$container_name\` in Pod \`$pod_name\`\\nReview Application Core Dumps and Stack Traces\\nCheck for Memory Corruption or Application Bugs\\nVerify DaemonSet Node-specific Dependencies\\nSIGABRT is usually a serious error - if it doesn't appear application related, escalate to the service or infrastructure owner for further investigation"
                    issue_details="{\"severity\":\"2\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to SIGABRT in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$sigabrt_next_steps\",\"details\":\"$detailed_info\"}"
                    ;;
                "Pod terminated by SIGKILL - Possible OOM")
                    if [[ $message =~ "Pod was terminated in response to imminent node shutdown." ]]; then
                        echo "Container terminated by SIGKILL related to node shutdown."
                        detailed_info="**Container Details:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total)\\n- Exit Code: $terminated_exitCode\\n- Terminated At: $terminated_finishedAt\\n- Reason: Node shutdown"
                        issue_details="{\"severity\":\"4\",\"title\":\"DaemonSet \`$owner_name\` in namespace \`${NAMESPACE}\` was evicted due to node shutdown\",\"next_steps\":\"Inspect DaemonSet replicas for \`$owner_name\`\\nVerify DaemonSet pod redistribution after node recovery\",\"details\":\"$detailed_info\"}"
                    else
                        # Analyze the actual cause of SIGKILL (exit 137)
                        analyze_sigkill_cause "$pod_name" "$container_name" "$terminated_finishedAt"
                        sigkill_cause=$?
                        
                        case $sigkill_cause in
                            1) # OOM Kill confirmed
                                echo "Container terminated by SIGKILL due to Out Of Memory (OOM). Container exceeded memory limits."
                                detailed_info="**Container OOM Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode (SIGKILL)\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE\\n- Root Cause: **CONFIRMED OOM KILL**\\n\\n**Analysis:** Container was terminated by the kernel OOM killer due to memory pressure. This indicates the container exceeded its memory limit or the node ran out of available memory. OOM events were detected in the pod events."
                                oom_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nGet Container Resource Utilization for \`$container_name\` in Pod \`$pod_name\`\\nGet Pod Resource Utilization with Top in Namespace \`$NAMESPACE\`\\nShow Pods Without Resource Limit or Resource Requests Set in Namespace \`$NAMESPACE\`\\nIdentify Resource Constrained Pods In Namespace \`$NAMESPACE\`\\nCheck Node Resource Utilization and Capacity\\nReview Memory Usage Patterns and Optimize Application\\nCheck DaemonSet Memory Limits and Requests"
                                issue_details="{\"severity\":\"2\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to OOM in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$oom_next_steps\",\"details\":\"$detailed_info\"}"
                                ;;
                            2) # Liveness Probe Failure confirmed
                                echo "Container terminated by SIGKILL due to liveness probe failure. Application failed health checks."
                                detailed_info="**Container Liveness Probe Failure Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode (SIGKILL)\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE\\n- Root Cause: **LIVENESS PROBE FAILURE**\\n\\n**Analysis:** Container was killed by Kubernetes due to failing liveness probe checks. The application was not responding to health checks, indicating it was unhealthy or unresponsive. This is NOT an OOM issue."
                                probe_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nCheck Liveness Probe Configuration for DaemonSet \`$owner_name\`\\nGet Container Resource Utilization for \`$container_name\` in Pod \`$pod_name\`\\nReview Application Health Check Endpoints\\nAnalyze Application Performance and Response Times\\nConsider Adjusting Liveness Probe Timeouts and Thresholds\\nVerify DaemonSet Node-specific Service Dependencies"
                                issue_details="{\"severity\":\"2\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to liveness probe failures in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$probe_next_steps\",\"details\":\"$detailed_info\"}"
                                ;;
                            3) # Other SIGKILL cause (preemption, etc.)
                                echo "Container terminated by SIGKILL due to system-level termination (preemption, eviction, or resource pressure)."
                                detailed_info="**Container System Termination Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode (SIGKILL)\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE\\n- Root Cause: **SYSTEM-LEVEL TERMINATION**\\n\\n**Analysis:** Container was terminated by system-level events such as pod preemption, node resource pressure, or cluster scheduling decisions. This is typically not an application issue."
                                system_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nInspect DaemonSet Warning Events for \`$owner_name\`\\nCheck Node Resource Utilization and Capacity\\nReview Pod Priority Classes and Resource Requests\\nAnalyze Cluster Scheduling and Eviction Policies\\nVerify DaemonSet Node Affinity and Tolerations"
                                issue_details="{\"severity\":\"3\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to system termination in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$system_next_steps\",\"details\":\"$detailed_info\"}"
                                ;;
                            *) # Unknown/unclear cause - default to original behavior but with better analysis
                                echo "Container terminated by SIGKILL - cause unclear. Requires investigation to determine if OOM, probe failure, or other issue."
                                detailed_info="**Container SIGKILL Analysis (Cause Unclear):**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode (SIGKILL)\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE\\n- Root Cause: **REQUIRES INVESTIGATION**\\n\\n**Analysis:** Container was terminated by SIGKILL but the specific cause could not be determined from available events and status. Could be OOM, liveness probe failure, or other system-level termination."
                                unclear_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nInspect DaemonSet Warning Events for \`$owner_name\`\\nGet Container Resource Utilization for \`$container_name\` in Pod \`$pod_name\`\\nCheck Liveness Probe Configuration for DaemonSet \`$owner_name\`\\nAnalyze Pod Events and System Logs for Root Cause\\nVerify DaemonSet Node Dependencies and Access"
                                issue_details="{\"severity\":\"2\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to unclear SIGKILL cause in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$unclear_next_steps\",\"details\":\"$detailed_info\"}"
                                ;;
                        esac
                    fi
                    ;;
                "Graceful Termination SIGTERM")
                    echo "Container received SIGTERM signal for graceful termination.Ensure that the container's shutdown process is handling SIGTERM correctly. This may be a normal part of the pod lifecycle."
                    detailed_info="**Container Restart Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode (SIGTERM)\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE (most recent restart within this timeframe)\\n\\n**Analysis:** Container received SIGTERM signal for graceful termination. This is usually part of normal pod lifecycle but frequent occurrences may indicate issues with shutdown handling."
                    sigterm_next_steps="Check Container Resource Utilization for \`$container_name\` in Pod \`$pod_name\`\\nReview Application Shutdown Handling and Grace Period\\nCheck Pod Lifecycle Events and Scheduling Patterns\\nVerify DaemonSet Update Strategy and Rolling Updates\\nIf SIGTERM is frequently occuring, escalate to the service or infrastructure owner for further investigation"
                    issue_details="{\"severity\":\"4\",\"title\":\"DaemonSet \`$owner_name\` has container restarts due to SIGTERM in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$sigterm_next_steps\",\"details\":\"$detailed_info\"}"
                    ;;
                *)
                    echo "Unknown exit code for pod \`$pod_name\`: $exit_code_explanation"
                    echo "$item"
                    # Handle unknown exit codes here
                    detailed_info="**Container Restart Analysis:**\\n- Pod: \`$pod_name\`\\n- Container: \`$container_name\`\\n- Total Restart Count: $restart_count (lifetime total, threshold: $CONTAINER_RESTART_THRESHOLD)\\n- Exit Code: $terminated_exitCode\\n- Terminated Reason: $terminated_reason\\n- Last Termination: $terminated_finishedAt\\n- Analysis Window: $CONTAINER_RESTART_AGE (most recent restart within this timeframe)\\n\\n**Analysis:** Unknown exit code detected. This may indicate an unusual termination condition that requires investigation."
                    unknown_next_steps="Check DaemonSet Log for Issues with \`$owner_name\`\\nGet Container Resource Utilization for \`$container_name\` in Pod \`$pod_name\`\\nReview Container Events and System Logs\\nVerify DaemonSet Configuration and Node Dependencies\\nUnknown exit code for pod \`$pod_name\` - escalate to the service or infrastructure owner for further investigation"
                    issue_details="{\"severity\":\"3\",\"title\":\"DaemonSet \`$owner_name\` has container restarts with unknown exit code in namespace \`${NAMESPACE}\`\",\"next_steps\":\"$unknown_next_steps\",\"details\":\"$detailed_info\"}"
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
                issues="$issues$issue_details]"
            fi
        fi
        
    done <<< "$container_list"
done <<< "$containers"

# Output the final issues JSON
if [ -n "$issues" ] && [ "$issues" != "[]" ]; then
    echo "$issues" | jq .
else
    echo "[]"
fi
