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
    next_steps+=("Troubleshoot Deployment Replicas for \`$owner_name\`")
fi

if [[ $messages =~ "Misconfiguration" && $owner_kind == "Deployment" ]]; then
    next_steps+=("Check Deployment Log For Issues for \`$owner_name\`")
    next_steps+=("Get Deployment Workload Details For \`$owner_name\` and Add to Report")
fi

if [[ $messages =~ "Deployment does not have minimum availability" && $owner_kind == "Deployment" ]]; then
    next_steps+=("Troubleshoot Deployment Warning Events for \`$owner_name\`")
    next_steps+=("Troubleshoot Container Restarts In Namespace \`$NAMESPACE\`")
fi


if [[ $messages =~ "ContainersNotReady" && $owner_kind == "StatefulSet" ]]; then
    next_steps+=("Troubleshoot StatefulSet Replicas for \`$owner_name\`")
fi

if [[ $messages =~ "Misconfiguration" && $owner_kind == "StatefulSet" ]]; then
    next_steps+=("Check StatefulSet Log For Issues for \`$owner_name\`")
    next_steps+=("Get StatefulSet Workload Details For \`$owner_name\` and Add to Report")
fi

if [[ $messages =~ "StatefulSet does not have minimum availability" && $owner_kind == "StatefulSet" ]]; then
    next_steps+=("Troubleshoot StatefulSet Warning Events for \`$owner_name\`")
    next_steps+=("Troubleshoot Container Restarts In Namespace \`$NAMESPACE\`")
fi


if [[ $messages =~ "ContainersNotReady" && $owner_kind == "DaemonSet" ]]; then
    next_steps+=("Troubleshoot DaemonSet Status for \`$owner_name\`")
    next_steps+=("Check Node Affinity and Tolerations for DaemonSet \`$owner_name\`")
fi

if [[ $messages =~ "Misconfiguration" && $owner_kind == "DaemonSet" ]]; then
    next_steps+=("Check DaemonSet Log For Issues for \`$owner_name\`")
    next_steps+=("Get DaemonSet Workload Details For \`$owner_name\` and Add to Report")
    next_steps+=("Check Node Affinity and Tolerations for DaemonSet \`$owner_name\`")
fi

if [[ $messages =~ "DaemonSet does not have minimum availability" && $owner_kind == "DaemonSet" ]]; then
    next_steps+=("Troubleshoot DaemonSet Warning Events for \`$owner_name\`")
    next_steps+=("Check Node Affinity and Tolerations for DaemonSet \`$owner_name\`")
    next_steps+=("Troubleshoot Container Restarts In Namespace \`$NAMESPACE\`")
fi

if [[ $messages =~ "DaemonSet has no ready pods" && $owner_kind == "DaemonSet" ]]; then
    next_steps+=("Inspect DaemonSet Status for \`$owner_name\`")
    next_steps+=("Check Node Affinity and Tolerations for DaemonSet \`$owner_name\`")
    next_steps+=("Troubleshoot DaemonSet Warning Events for \`$owner_name\`")
    next_steps+=("Check for Node Failures or Maintenance Activities in Cluster \`$CONTEXT\`")
fi


if [[ $messages =~ "Misconfiguration" ]]; then
    next_steps+=("Review configuration of  owner_kind \`$owner_name\`")
    next_steps+=("Check for Node Failures or Maintenance Activities in Cluster \`$CONTEXT\`")
fi

if [[ $messages =~ "Liveness probe failed" || $messages =~ "Liveness probe errored" ]]; then
    next_steps+=("Check Liveliness Probe Configuration for $owner_kind \`$owner_name\`")
fi

if [[ $messages =~ "Readiness probe errored" || $messages =~ "Readiness probe failed" ]]; then
    next_steps+=("Check Readiness Probe Configuration for $owner_kind \`$owner_name\`")
fi

if [[ $messages =~ "ImagePullBackOff" || $messages =~ "Back-off pulling image" || $messages =~ "ErrImagePull" ]]; then
    next_steps+=("List ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`")
    next_steps+=("List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`")
fi

if [[ $messages =~ "ImagePullBackOff" || $messages =~ "Back-off pulling image" || $messages =~ "ErrImagePull" ]]; then
    next_steps+=("List ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`")
    next_steps+=("List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`")
fi


# Display the list of recommendations
printf "%s\n" "${next_steps[@]}" | sort | uniq 