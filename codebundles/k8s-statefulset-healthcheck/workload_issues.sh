#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# Kubernetes StatefulSet system and provides more concrete issue details in json format.
# This adapts the deployment version for StatefulSet-specific concerns like persistent storage
# and ordered pod deployment.
# -----------------------------------------------------------------------------
# Input: List of event messages, related owner kind, and related owner name
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

messages="$1"
owner_kind="$2"  
owner_name="$3"

issue_details_array=()

add_issue() {
    local severity=$1
    local title=$2
    local details=$3
    local next_steps=$4
    issue_details="{\"severity\":\"$severity\",\"title\":\"$title\",\"details\":\"$details\",\"next_steps\":\"$next_steps\"}"
    issue_details_array+=("$issue_details")
}

# Check conditions and add issues to the array for StatefulSet-specific scenarios
if echo "$messages" | grep -q "ContainersNotReady" && [[ $owner_kind == "StatefulSet" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has unready containers" "$messages" "Inspect StatefulSet Replicas for \`$owner_name\`\nCheck StatefulSet PersistentVolumeClaims for \`$owner_name\`"
fi

if echo "$messages" | grep -q "Misconfiguration" && [[ $owner_kind == "StatefulSet" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has a misconfiguration" "$messages" "Check StatefulSet Logs for Issues\nFetch StatefulSet Workload Details For \`$owner_name\` and Add to Report\nValidate PVC configurations"
fi

if echo "$messages" | grep -q "PodInitializing"; then
    add_issue "4" "$owner_kind \`$owner_name\` is initializing" "$messages" "Retry in a few minutes and verify that \`$owner_name\` is running.\nInspect $owner_kind Warning Events for \`$owner_name\`\nCheck ordered pod startup sequence"
fi

if echo "$messages" | grep -q "Startup probe failed"; then
    add_issue "2" "$owner_kind \`$owner_name\` is unable to start" "$messages" "Check Application Log Patterns for StatefulSet \`$owner_name\`\nCheck Readiness Probe Configuration for StatefulSet \`$owner_name\`\nIncrease Startup Probe Timeout and Threshold for StatefulSet \`$owner_name\`\nVerify persistent volume access and mounting"
fi

if echo "$messages" | grep -q "Liveness probe failed\|Liveness probe errored"; then
    add_issue "3" "$owner_kind \`$owner_name\` is restarting" "$messages" "Check Liveness Probe Configuration for StatefulSet \`$owner_name\`\nAnalyze Application Log Patterns for StatefulSet \`$owner_name\`"
fi

if echo "$messages" | grep -q "Readiness probe errored\|Readiness probe failed"; then
    add_issue "2" "$owner_kind \`$owner_name\` is unable to start" "$messages" "Check Readiness Probe Configuration for StatefulSet \`$owner_name\`\nVerify database/storage initialization if applicable"
fi

if echo "$messages" | grep -q "PodFailed"; then
    add_issue "2" "$owner_kind \`$owner_name\` has failed pods" "$messages" "Check Pod Status and Logs for Errors\nVerify persistent volume claims are bound\nCheck storage class configuration"
fi

if echo "$messages" | grep -q "ImagePullBackOff\|Back-off pulling image\|ErrImagePull"; then
    add_issue "2" "$owner_kind \`$owner_name\` has image access issues" "$messages" "List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`\nList ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`"
fi

if echo "$messages" | grep -q "Back-off restarting failed container"; then
    add_issue "2" "$owner_kind \`$owner_name\` has failing containers" "$messages" "Analyze Application Log Patterns for StatefulSet \`$owner_name\`\nInspect Warning Events for StatefulSet \`$owner_name\`\nCheck persistent storage access"
fi

if echo "$messages" | grep -q "forbidden: failed quota\|forbidden: exceeded quota"; then
    add_issue "3" "$owner_kind \`$owner_name\` has resources that cannot be scheduled" "$messages" "Adjust resource configuration for StatefulSet \`$owner_name\` according to issue details.\nCheck storage quota limits"
fi

if echo "$messages" | grep -q "is forbidden: \[minimum cpu usage per Container\|is forbidden: \[minimum memory usage per Container"; then
    add_issue "2" "$owner_kind \`$owner_name\` has invalid resource configuration" "$messages" "Adjust resource configuration for StatefulSet \`$owner_name\` according to issue details."
fi

if echo "$messages" | grep -q "No preemption victims found for incoming pod\|Insufficient cpu\|The node was low on resource\|nodes are available\|Preemption is not helpful"; then
    add_issue "2" "$owner_kind \`$owner_name\` cannot be scheduled - not enough cluster resources." "$messages" "Not enough node resources available to schedule pods. Escalate this issue to your cluster owner.\nIncrease Node Count in Cluster\nCheck for Quota Errors\nIdentify High Utilization Nodes for Cluster \`${CONTEXT}\`"
fi

if echo "$messages" | grep -q "max node group size reached"; then
    add_issue "2" "$owner_kind \`$owner_name\` cannot be scheduled - cannot increase cluster size." "$messages" "Not enough node resources available to schedule pods. Escalate this issue to your cluster owner.\nIncrease Max Node Group Size in Cluster\nIdentify High Utilization Nodes for Cluster \`${CONTEXT}\`"
fi

if echo "$messages" | grep -q "Health check failed after"; then
    add_issue "3" "$owner_kind \`$owner_name\` health check failed." "$messages" "Check StatefulSet \`$owner_name\` Health\nVerify data persistence and storage connectivity"
fi

# StatefulSet-specific issues
if echo "$messages" | grep -q "FailedMount\|MountVolume"; then
    add_issue "2" "$owner_kind \`$owner_name\` has persistent volume mounting issues" "$messages" "Check StatefulSet PersistentVolumeClaims for \`$owner_name\`\nVerify storage class configuration\nCheck persistent volume availability\nInvestigate storage node accessibility"
fi

if echo "$messages" | grep -q "pod has unbound immediate PersistentVolumeClaims"; then
    add_issue "2" "$owner_kind \`$owner_name\` has unbound persistent volume claims" "$messages" "Check StatefulSet PersistentVolumeClaims for \`$owner_name\`\nVerify storage class exists and is functional\nCheck persistent volume provisioner status\nVerify storage quota and node capacity"
fi

if echo "$messages" | grep -q "timeout expired waiting for volume to be created"; then
    add_issue "2" "$owner_kind \`$owner_name\` is waiting for persistent volume creation" "$messages" "Check StatefulSet PersistentVolumeClaims for \`$owner_name\`\nVerify storage provisioner is working\nCheck storage class configuration\nInvestigate storage backend availability"
fi

if echo "$messages" | grep -q "failed to update replica set\|StatefulSet does not have minimum availability"; then
    add_issue "3" "$owner_kind \`$owner_name\` is not available or updating." "$messages" "Inspect StatefulSet Warning Events for \`$owner_name\`\nCheck StatefulSet Replicas for \`$owner_name\`\nVerify ordered pod startup sequence"
fi

if echo "$messages" | grep -q "Pod with hostname"; then
    add_issue "3" "$owner_kind \`$owner_name\` has pod hostname conflicts" "$messages" "Check StatefulSet pod naming and ordering\nVerify headless service configuration\nInspect StatefulSet Warning Events for \`$owner_name\`"
fi

if echo "$messages" | grep -q "Created container server\|no changes since last reconcilation\|Reconciliation finished\|successfully rotated K8s secret"; then
    # Don't generate any issue data, these are normal strings
    echo "[]" | jq .
    exit 0
fi

if [ ${#issue_details_array[@]} -gt 0 ]; then
    issues_json=$(printf "%s," "${issue_details_array[@]}")
    issues_json="[${issues_json%,}]" # Remove the last comma and wrap in square brackets
    echo "$issues_json" | jq .
else
    echo "[{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has issues that require further investigation.\",\"details\":\"$messages\",\"next_steps\":\"Escalate issues for StatefulSet \`$owner_name\` to service owner\nCheck StatefulSet PersistentVolumeClaims for storage issues\nAnalyze Application Log Patterns for StatefulSet \`$owner_name\`\"}]" | jq .
fi 