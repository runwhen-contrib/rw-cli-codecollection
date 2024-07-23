#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script takes in event message strings captured from a 
# Kubernetes based system and provides some generalized next steps based on the 
# content and frequency of the message. 
# -----------------------------------------------------------------------------
# Input: List of event messages, related owner kind, and related owner name
messages="$1"
owner_kind="$2"  
owner_name="$3"

# Initialize an empty array to store recommendations
next_steps=()


if [[ $messages =~ "ContainersNotReady" && $owner_kind == "Deployment" ]]; then
    next_steps+=("Inspect Deployment Replicas for \`$owner_name\`")
fi

if [[ $messages =~ "Misconfiguration" && $owner_kind == "Deployment" ]]; then
    next_steps+=("Check Deployment Log For Issues for \`$owner_name\`")
    next_steps+=("Get Deployment Workload Details For \`$owner_name\` and Add to Report")
fi

if [[ $messages =~ "Misconfiguration" ]]; then
    next_steps+=("Review configuration of $owner_kind \`$owner_name\`")
    next_steps+=("Check for Node Failures or Maintenance Activities in Cluster \`$CONTEXT\`")
fi

if [[ $messages =~ "PodInitializing" ]]; then
    next_steps+=("Check $owner_kind Health for \`$owner_name\`")
    next_steps+=("Inspect $owner_kind Warning Events for \`$owner_name\`")
fi

if [[ $messages =~ "Startup probe failed" ]]; then
    add_issue "2" "$owner_kind \`$owner_name\` is unable to start" "$messages" "Check Deployment Logs for $owner_kind \`$owner_name\`\nReview Startup Probe Configuration for $owner_kind \`$owner_name\`\nIncrease Startup Probe Timeout and Threshold for $owner_kind \`$owner_name\`\nIdentify Resource Constrained Pods In Namespace \`$NAMESPACE\`"
fi

if [[ $messages =~ "Liveness probe failed" || $messages =~ "Liveness probe errored" ]]; then
    next_steps+=("Check Liveliness Probe Configuration for $owner_kind \`$owner_name\`")
fi

if [[ $messages =~ "Readiness probe errored" || $messages =~ "Readiness probe failed" ]]; then
    next_steps+=("Check Readiness Probe Configuration for $owner_kind \`$owner_name\`")
fi

if [[ $messages =~ "PodFailed" ]]; then
    next_steps+=("Check Readiness Probe Configuration for $owner_kind \`$owner_name\`")
fi

if [[ $messages =~ "ImagePullBackOff" || $messages =~ "Back-off pulling image" || $messages =~ "ErrImagePull" ]]; then
    next_steps+=("List ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`")
    next_steps+=("List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`")
fi

if [[ $messages =~ "Back-off restarting failed container" ]]; then
    next_steps+=("Check Log for $owner_kind \`$owner_name\`")
    next_steps+=("Inspect Warning Events for $owner_kind \`$owner_name\`")

fi

if [[ $messages =~ "ImagePullBackOff" || $messages =~ "Back-off pulling image" || $messages =~ "ErrImagePull" ]]; then
    next_steps+=("List ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`")
    next_steps+=("List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`")
fi

if [[ $messages =~ "forbidden: failed quota" || $messages =~ "forbidden: exceeded quota" ]]; then
    next_steps+=("Check Resource Quota Utilization in Namepace \`$NAMESPACE\`")
fi

if [[ $messages =~ "No preemption victims found for incoming pod" || $messages =~ "Insufficient cpu" ]]; then
    next_steps+=("Not enough node resources available to schedule pods. Escalate this issue to the service owner of cluster context \`$CONTEXT\`. ")
    next_steps+=("Increase node count in cluster context \`$CONTEXT\`")
    next_steps+=("Check Cloud Provider Quota Errors")
fi

if [[ $messages =~ "max node group size reached" ]]; then
    next_steps+=("Not enough node resources available to schedule pods. Escalate this issue to the service owner of cluster context \`$CONTEXT\`")
    next_steps+=("Increase node count in cluster context \`$CONTEXT\`")
    next_steps+=("Check Cloud Provider Quota Errors")
fi

if [[ $messages =~ "Health check failed after" ]]; then
    next_steps+=("Check $owner_kind \`$owner_name\` Health")
fi

if [[ $messages =~ "Deployment does not have minimum availability" ]]; then
    next_steps+=("Inspect Deployment Warning Events for \`$owner_name\`")
fi

if [[ ${#next_steps[@]} -eq 0 ]]; then
    next_steps+=("Please review the report logs and escalate the issue if necessary.")
fi

# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq
