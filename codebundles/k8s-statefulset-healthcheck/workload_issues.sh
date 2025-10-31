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
messages="$1"
owner_kind="$2"  
owner_name="$3"
event_timestamp="$4"

issue_details_array=()

add_issue() {
    local severity=$1
    local title=$2
    local details=$3
    local next_steps=$4
    issue_details="{\"severity\":\"$severity\",\"title\":\"$title\",\"details\":\"$details\",\"next_steps\":\"$next_steps\",\"observed_at\":\"$event_timestamp\"}"
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
    echo "[{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has issues that require further investigation.\",\"details\":\"$messages\",\"next_steps\":\"Escalate issues for StatefulSet \`$owner_name\` to service owner\nCheck StatefulSet PersistentVolumeClaims for storage issues\nAnalyze Application Log Patterns for StatefulSet \`$owner_name\`\",\"observed_at\":\"$event_timestamp\"}]" | jq .
fi 