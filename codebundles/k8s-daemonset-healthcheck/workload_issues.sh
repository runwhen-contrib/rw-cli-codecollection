#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# Kubernetes DaemonSet system and provides more concrete issue details in json format.
# This adapts the StatefulSet version for DaemonSet-specific concerns like node scheduling,
# tolerations, and daemon processes running on specific nodes.
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

# Check conditions and add issues to the array for DaemonSet-specific scenarios
if echo "$messages" | grep -q "ContainersNotReady" && [[ $owner_kind == "DaemonSet" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has unready containers" "$messages" "Inspect DaemonSet Status for \`$owner_name\`\nCheck Node Affinity and Tolerations for DaemonSet \`$owner_name\`"
fi

if echo "$messages" | grep -q "Misconfiguration" && [[ $owner_kind == "DaemonSet" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` has a misconfiguration" "$messages" "Check DaemonSet Logs for Issues\nFetch DaemonSet Workload Details For \`$owner_name\` and Add to Report\nValidate node selector and toleration configurations"
fi

if echo "$messages" | grep -q "PodInitializing"; then
    add_issue "4" "$owner_kind \`$owner_name\` is initializing" "$messages" "Retry in a few minutes and verify that \`$owner_name\` is running.\nInspect DaemonSet Warning Events for \`$owner_name\`\nCheck node affinity requirements"
fi

if echo "$messages" | grep -q "Startup probe failed"; then
    add_issue "2" "$owner_kind \`$owner_name\` is unable to start" "$messages" "Check Application Log Patterns for DaemonSet \`$owner_name\`\nCheck Readiness Probe Configuration for DaemonSet \`$owner_name\`\nIncrease Startup Probe Timeout and Threshold for DaemonSet \`$owner_name\`\nVerify node-specific resources and privileges"
fi

if echo "$messages" | grep -q "Liveness probe failed\|Liveness probe errored"; then
    add_issue "3" "$owner_kind \`$owner_name\` is restarting" "$messages" "Check Liveness Probe Configuration for DaemonSet \`$owner_name\`\nAnalyze Application Log Patterns for DaemonSet \`$owner_name\`"
fi

if echo "$messages" | grep -q "Readiness probe errored\|Readiness probe failed"; then
    add_issue "2" "$owner_kind \`$owner_name\` is unable to start" "$messages" "Check Readiness Probe Configuration for DaemonSet \`$owner_name\`\nVerify node-specific services and connections"
fi

if echo "$messages" | grep -q "PodFailed"; then
    add_issue "2" "$owner_kind \`$owner_name\` has failed pods" "$messages" "Check Pod Status and Logs for Errors\nInspect node conditions and taints\nVerify DaemonSet tolerations"
fi

if echo "$messages" | grep -q "ImagePullBackOff\|Back-off pulling image\|ErrImagePull"; then
    add_issue "2" "$owner_kind \`$owner_name\` has image access issues" "$messages" "List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`\nList ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`"
fi

if echo "$messages" | grep -q "Back-off restarting failed container"; then
    add_issue "2" "$owner_kind \`$owner_name\` has failing containers" "$messages" "Analyze Application Log Patterns for DaemonSet \`$owner_name\`\nInspect Warning Events for DaemonSet \`$owner_name\`\nCheck node-specific resource access"
fi

if echo "$messages" | grep -q "forbidden: failed quota\|forbidden: exceeded quota"; then
    add_issue "3" "$owner_kind \`$owner_name\` has resources that cannot be scheduled" "$messages" "Adjust resource configuration for DaemonSet \`$owner_name\` according to issue details.\nCheck node resource allocation"
fi

if echo "$messages" | grep -q "is forbidden: \[minimum cpu usage per Container\|is forbidden: \[minimum memory usage per Container"; then
    add_issue "2" "$owner_kind \`$owner_name\` has invalid resource configuration" "$messages" "Adjust resource configuration for DaemonSet \`$owner_name\` according to issue details."
fi

if echo "$messages" | grep -q "No preemption victims found for incoming pod\|Insufficient cpu\|The node was low on resource\|nodes are available\|Preemption is not helpful"; then
    add_issue "2" "$owner_kind \`$owner_name\` cannot be scheduled - not enough node resources." "$messages" "Not enough node resources available to schedule daemon pods. Escalate this issue to your cluster owner.\nIncrease Node Count in Cluster\nCheck for Quota Errors\nIdentify High Utilization Nodes for Cluster \`${CONTEXT}\`"
fi

if echo "$messages" | grep -q "max node group size reached"; then
    add_issue "2" "$owner_kind \`$owner_name\` cannot be scheduled - cannot increase cluster size." "$messages" "Not enough node resources available to schedule daemon pods. Escalate this issue to your cluster owner.\nIncrease Max Node Group Size in Cluster\nIdentify High Utilization Nodes for Cluster \`${CONTEXT}\`"
fi

if echo "$messages" | grep -q "Health check failed after"; then
    add_issue "3" "$owner_kind \`$owner_name\` health check failed." "$messages" "Check DaemonSet \`$owner_name\` Health\nVerify node-specific daemon functionality"
fi

# DaemonSet-specific issues
if echo "$messages" | grep -q "FailedNodeAffinity\|NodeAffinity"; then
    add_issue "2" "$owner_kind \`$owner_name\` has node affinity scheduling issues" "$messages" "Check Node Affinity and Tolerations for DaemonSet \`$owner_name\`\nVerify node labels match affinity requirements\nCheck node availability and status\nReview DaemonSet scheduling constraints"
fi

if echo "$messages" | grep -q "PodToleratesNodeTaints\|NoExecute\|NoSchedule"; then
    add_issue "2" "$owner_kind \`$owner_name\` has node taint tolerance issues" "$messages" "Check Node Affinity and Tolerations for DaemonSet \`$owner_name\`\nAdd appropriate tolerations to DaemonSet spec\nVerify node taints configuration\nCheck scheduling policies"
fi

if echo "$messages" | grep -q "didn't match node selector\|NodeSelectorMismatching"; then
    add_issue "2" "$owner_kind \`$owner_name\` has node selector issues" "$messages" "Check Node Affinity and Tolerations for DaemonSet \`$owner_name\`\nVerify node labels match selector requirements\nUpdate node selector or node labels as needed"
fi

if echo "$messages" | grep -q "HostPortConflict\|host port"; then
    add_issue "2" "$owner_kind \`$owner_name\` has host port conflicts" "$messages" "Resolve host port conflicts on nodes\nCheck for other pods using same host ports\nModify DaemonSet port configuration if needed\nInspect DaemonSet Warning Events for \`$owner_name\`"
fi

if echo "$messages" | grep -q "HostPathMount\|host path"; then
    add_issue "3" "$owner_kind \`$owner_name\` has host path mounting issues" "$messages" "Verify host path exists on target nodes\nCheck node filesystem permissions\nValidate security context and volume configurations\nVerify node readiness and accessibility"
fi

if echo "$messages" | grep -q "daemon pod can't be deleted"; then
    add_issue "3" "$owner_kind \`$owner_name\` has pod deletion issues" "$messages" "Check for finalizers blocking pod deletion\nVerify node connectivity and kubelet status\nInspect DaemonSet Warning Events for \`$owner_name\`\nCheck for stuck daemon processes"
fi

if echo "$messages" | grep -q "FailedScheduling.*node.*didn't match.*scheduler"; then
    add_issue "2" "$owner_kind \`$owner_name\` has scheduling failures across nodes" "$messages" "Check Node Affinity and Tolerations for DaemonSet \`$owner_name\`\nVerify node readiness and availability\nCheck cluster scheduler health\nReview node capacity and resource availability"
fi

if echo "$messages" | grep -q "exceeded the number of tolerated failures"; then
    add_issue "2" "$owner_kind \`$owner_name\` has exceeded tolerated node failures" "$messages" "Investigate node health and availability\nCheck for infrastructure issues affecting multiple nodes\nReview DaemonSet restart policies\nInspect DaemonSet Warning Events for \`$owner_name\`"
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
    echo "[{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` has issues that require further investigation.\",\"details\":\"$messages\",\"next_steps\":\"Escalate issues for DaemonSet \`$owner_name\` to service owner\nCheck Node Affinity and Tolerations for DaemonSet \`$owner_name\`\nAnalyze Application Log Patterns for DaemonSet \`$owner_name\`\nInspect node conditions and scheduling constraints\",\"observed_at\":\"$event_timestamp\"}]" | jq .
fi 