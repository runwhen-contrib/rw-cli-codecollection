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

if echo "$messages" | grep -q "ContainersNotReady" && [[ $owner_kind == "Deployment" ]]; then
    next_steps+=("Inspect Deployment Replicas for \`$owner_name\`")
fi

if echo "$messages" | grep -q "ContainersNotReady\|containers with unready status"; then
    next_steps+=("Check container restarts for $owner_kind \`$owner_name\`")
fi

if echo "$messages" | grep -q "Misconfiguration" && [[ $owner_kind == "Deployment" ]]; then
    next_steps+=("Check Deployment Log For Issues for \`$owner_name\`")
    next_steps+=("Get Deployment Workload Details For \`$owner_name\` and Add to Report")
fi

if echo "$messages" | grep -q "Misconfiguration"; then
    next_steps+=("Review configuration of $owner_kind \`$owner_name\`")
    next_steps+=("Check for Node Failures or Maintenance Activities in Cluster \`$CONTEXT\`")
fi

if echo "$messages" | grep -q "PodInitializing"; then
    next_steps+=("Check $owner_kind Health for \`$owner_name\`")
    next_steps+=("Inspect $owner_kind Warning Events for \`$owner_name\`")
fi

if echo "$messages" | grep -q "Liveness probe failed\|Liveness probe errored"; then
    next_steps+=("Check Liveliness Probe Configuration for $owner_kind \`$owner_name\`")
fi

if echo "$messages" | grep -q "Readiness probe errored\|Readiness probe failed"; then
    next_steps+=("Check Readiness Probe Configuration for $owner_kind \`$owner_name\`")
fi

if echo "$messages" | grep -q "PodFailed"; then
    next_steps+=("Check Readiness Probe Configuration for $owner_kind \`$owner_name\`")
fi

if echo "$messages" | grep -q "ImagePullBackOff\|Back-off pulling image\|ErrImagePull"; then
    next_steps+=("List ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`")
    next_steps+=("List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`")
fi

if echo "$messages" | grep -q "Back-off restarting failed container"; then
    next_steps+=("Check Log for $owner_kind \`$owner_name\`")
    next_steps+=("Inspect Warning Events for $owner_kind \`$owner_name\`")
fi

if echo "$messages" | grep -q "forbidden: failed quota\|forbidden: exceeded quota"; then
    next_steps+=("Check Resource Quota Utilization in Namepace \`$NAMESPACE\`")
fi

if echo "$messages" | grep -q "No preemption victims found for incoming pod\|Insufficient cpu"; then
    next_steps+=("Not enough node resources available to schedule pods. Escalate this issue to the service owner of cluster context \`$CONTEXT\`. ")
    next_steps+=("Increase node count in cluster context \`$CONTEXT\`")
    next_steps+=("Check Cloud Provider Quota Errors")
fi

if echo "$messages" | grep -q "max node group size reached"; then
    next_steps+=("Not enough node resources available to schedule pods. Escalate this issue to the service owner of cluster context \`$CONTEXT\`")
    next_steps+=("Increase node count in cluster context \`$CONTEXT\`")
    next_steps+=("Check Cloud Provider Quota Errors")
fi

if echo "$messages" | grep -q "Health check failed after"; then
    next_steps+=("Check $owner_kind \`$owner_name\` Health")
fi

if echo "$messages" | grep -q "Deployment does not have minimum availability"; then
    next_steps+=("Inspect Deployment Warning Events for \`$owner_name\`")
fi

if echo "$messages" | grep -q "Pod was terminated in response to imminent node shutdown\|TerminationByKubelet"; then
    next_steps+=("Verify $owner_kind \`$owner_name\` health.")
    next_steps+=("Verify node restarts or maintenance activities are expected health.")
fi

if echo "$messages" | grep -q "Startup probe failed"; then
    next_steps+=("Check Startup Probe Configuration for $owner_kind \`$owner_name\`")
fi

## Exit on normal strings
if echo "$messages" | grep -q "Created container server\|no changes since last reconcilation\|Reconciliation finished\|successfully rotated K8s secret"; then
    # Don't generate any issue data, these are normal strings
    exit 0
fi

## Catch All
if [[ ${#next_steps[@]} -eq 0 ]]; then
    next_steps+=("Please review the report logs and escalate the issue if necessary.")
fi

# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq
