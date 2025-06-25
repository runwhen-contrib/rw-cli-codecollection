#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# Kubernetes based system and provides more concrete issue details in json format. This is a migration away from workload_next_steps.sh in order to support dynamic severity generation and more robust next step details. 
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
if echo "$messages" | grep -q "ContainersNotReady" && [[ $owner_kind == "Deployment" ]]; then
    add_issue "2" "Unready containers" "$messages" "Inspect Deployment Replicas"
fi

if echo "$messages" | grep -q "Misconfiguration" && [[ $owner_kind == "Deployment" ]]; then
    add_issue "2" "Misconfiguration" "$messages" "Check Deployment Log For Issues\nGet Deployment Workload Details and Add to Report"
fi

if echo "$messages" | grep -q "PodInitializing"; then
    add_issue "4" "Pods initializing" "$messages" "Retry in a few minutes and verify that workload is running.\nInspect Warning Events"
fi

if echo "$messages" | grep -q "Startup probe failed"; then
    add_issue "2" "Startup probe failure" "$messages" "Check Deployment Logs\nReview Startup Probe Configuration\nIncrease Startup Probe Timeout and Threshold\nIdentify Resource Constrained Pods In Namespace \`$NAMESPACE\`"
fi

if echo "$messages" | grep -q "Liveness probe failed\|Liveness probe errored"; then
    add_issue "3" "Liveness probe failure" "$messages" "Check Liveliness Probe Configuration"
fi

if echo "$messages" | grep -q "Readiness probe errored\|Readiness probe failed"; then
    add_issue "2" "Readiness probe failure" "$messages" "Check Readiness Probe Configuration"
fi

if echo "$messages" | grep -q "PodFailed"; then
    add_issue "2" "Pod failure" "$messages" "Check Pod Status and Logs for Errors"
fi

if echo "$messages" | grep -q "ImagePullBackOff\|Back-off pulling image\|ErrImagePull"; then
    add_issue "2" "Image pull failure" "$messages" "List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`\nList ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`"
fi

if echo "$messages" | grep -q "Back-off restarting failed container"; then
    add_issue "2" "Container restart failure" "$messages" "Check Deployment Log\nInspect Warning Events"
fi

if echo "$messages" | grep -q "forbidden: failed quota\|forbidden: exceeded quota"; then
    add_issue "3" "Resource quota exceeded" "$messages" "Adjust resource configuration according to issue details."
fi

if echo "$messages" | grep -q "is forbidden: \[minimum cpu usage per Container\|is forbidden: \[minimum memory usage per Container"; then
    add_issue "2" "Invalid resource configuration" "$messages" "Adjust resource configuration according to issue details."
fi

if echo "$messages" | grep -q "No preemption victims found for incoming pod\|Insufficient cpu\|The node was low on resource\|nodes are available\|Preemption is not helpful"; then
    add_issue "2" "Insufficient cluster resources" "$messages" "Not enough node resources available to schedule pods. Escalate this issue to your cluster owner.\nIncrease Node Count in Cluster\nCheck for Quota Errors\nIdentify High Utilization Nodes for Cluster \`${CONTEXT}\`"
fi

if echo "$messages" | grep -q "max node group size reached"; then
    add_issue "2" "Cluster autoscaling limit reached" "$messages" "Not enough node resources available to schedule pods. Escalate this issue to your cluster owner.\nIncrease Max Node Group Size in Cluster\nIdentify High Utilization Nodes for Cluster \`${CONTEXT}\`"
fi

if echo "$messages" | grep -q "Health check failed after"; then
    add_issue "3" "Health check failure" "$messages" "Check Health"
fi

if echo "$messages" | grep -q "Deployment does not have minimum availability"; then
    add_issue "3" "Minimum availability not met" "$messages" "Inspect Deployment Warning Events"
fi

if echo "$messages" | grep -q "Created container server\|no changes since last reconcilation\|Reconciliation finished\|successfully rotated K8s secret"; then
    # Don't generate any issue data, these are normal strings
    echo "[]" | jq .
    exit 0
fi

### These are ChatGPT Generated and will require tuning. Please migrate above this line when tuned. 
## Removed for now - they were getting wildly off-base
### End of auto-generated message strings

if [ ${#issue_details_array[@]} -gt 0 ]; then
    issues_json=$(printf "%s," "${issue_details_array[@]}")
    issues_json="[${issues_json%,}]" # Remove the last comma and wrap in square brackets
    echo "$issues_json" | jq .
else
    echo "[{\"severity\":\"4\",\"title\":\"Requires investigation\",\"details\":\"$messages\",\"next_steps\":\"Escalate issues to service owner \"}]" | jq .
fi
