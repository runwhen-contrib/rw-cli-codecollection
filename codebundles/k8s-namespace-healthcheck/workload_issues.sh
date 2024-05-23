#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# Kubernetes based system and provides more concrete issue details in json format. This is a migratio naway from workload_next_steps.sh in order to support dynamic severity generation and more robust next step details. 
# -----------------------------------------------------------------------------
# Input: List of event messages, related owner kind, and related owner name
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

# Check conditions and add issues to the array
if [[ $messages =~ "ContainersNotReady" && $owner_kind == "Deployment" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has unready containers" "$messages" "Troubleshoot Deployment Replicas for \`$owner_name\`"
fi

if [[ $messages =~ "Misconfiguration" && $owner_kind == "Deployment" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has a misconfiguration" "$messages" "Check Deployment Log For Issues for \`$owner_name\`\nGet Deployment Workload Details For \`$owner_name\` and Add to Report"
fi

if [[ $messages =~ "PodInitializing" ]]; then
    add_issue "4" "$owner_kind \`$owner_name\` is initializing" "$messages" "Retry in a few minutes and verify that \`$owner_name\` is running.\nTroubleshoot $owner_kind Warning Events for \`$owner_name\`"
fi

if [[ $messages =~ "Liveness probe failed" || $messages =~ "Liveness probe errored" ]]; then
    add_issue "3" "$owner_kind \`$owner_name\` is restarting" "$messages" "Check Liveliness Probe Configuration for $owner_kind \`$owner_name\`"
fi

if [[ $messages =~ "Readiness probe errored" || $messages =~ "Readiness probe failed" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` is unable to start" "$messages" "Check Readiness Probe Configuration for $owner_kind \`$owner_name\`"
fi

if [[ $messages =~ "PodFailed" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has failed pods" "$messages" "Check Pod Status and Logs for Errors"
fi

if [[ $messages =~ "ImagePullBackOff" || $messages =~ "Back-off pulling image" || $messages =~ "ErrImagePull" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has image access issues" "$messages" "List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`\nList ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`"
fi

if [[ $messages =~ "Back-off restarting failed container" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has failing containers" "$messages" "Check $owner_kind Log for \`$owner_name\`\nTroubleshoot Warning Events for $owner_kind \`$owner_name\`"
fi

if [[ $messages =~ "forbidden: failed quota" || $messages =~ "forbidden: exceeded quota" ]]; then
    add_issue "3" "$owner_kind \`$owner_name\` has resources that cannot be scheduled" "$messages" "Adjust resource configuration for $owner_kind \`$owner_name\` according to issue details."
fi

if [[ $messages =~ "is forbidden: [minimum cpu usage per Container" || $messages =~ "is forbidden: [minimum memory usage per Container" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has invalid resource configuration" "$messages" "Adjust resource configuration for $owner_kind \`$owner_name\` according to issue details."
fi

if [[ $messages =~ "No preemption victims found for incoming pod" || $messages =~ "Insufficient cpu" || $messages =~ "The node was low on resource" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` cannot be scheduled - not enough cluster resources." "$messages" "Not enough node resources available to schedule pods. Escalate this issue to your cluster owner.\nIncrease Node Count in Cluster\nCheck for Quota Errors\nIdentify High Utilization Nodes for Cluster \`${CONTEXT}\`"
fi

if [[ $messages =~ "max node group size reached" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` cannot be scheduled - cannot increase cluster size." "$messages" "Not enough node resources available to schedule pods. Escalate this issue to your cluster owner.\nIncrease Max Node Group Size in Cluster\nIdentify High Utilization Nodes for Cluster \`${CONTEXT}\`"
fi

if [[ $messages =~ "Health check failed after" ]]; then
    add_issue "3" "$owner_kind \`$owner_name\` health check failed." "$messages" "Check $owner_kind \`$owner_name\` Health"
fi

if [[ $messages =~ "Deployment does not have minimum availability" ]]; then
    add_issue "3" "$owner_kind \`$owner_name\` is not available." "$messages" "Troubleshoot Deployment Warning Events for \`$owner_name\`"
fi


### These are ChatGPT Generated and will require tuning. Please migrate above this line when tuned. 
## Removed for now - they were getting wildly off-base
### End of auto-generated message strings

if [ ${#issue_details_array[@]} -gt 0 ]; then
    issues_json=$(printf "%s," "${issue_details_array[@]}")
    issues_json="[${issues_json%,}]" # Remove the last comma and wrap in square brackets
    echo "$issues_json" | jq .
else
    echo "[{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has issues that require further investigation.\",\"details\":\"$messages\",\"next_steps\":\"Escalate issues for $owner_kind \`$owner_name\` to service owner \"}]" | jq .
fi