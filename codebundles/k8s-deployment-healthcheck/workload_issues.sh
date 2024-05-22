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

if [[ $messages =~ "ContainersNotReady" && $owner_kind == "Deployment" ]]; then
    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has unready containers\",\"details\":\"$messages\",\"next_steps\":\"Troubleshoot Deployment Replicas for \`$owner_name\`\"}"
fi

if [[ $messages =~ "Misconfiguration" && $owner_kind == "Deployment" ]]; then
    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has a misconfiguration\",\"details\":\"$messages\",\"next_steps\":\"Check Deployment Log For Issues for \`$owner_name\`\nGet Deployment Workload Details For \`$owner_name\` and Add to Report\"}"
fi

if [[ $messages =~ "PodInitializing" ]]; then
    issue_details="{\"severity\":\"4\",\"title\":\"$owner_kind \`$owner_name\` is initializing\",\"details\":\"$messages\",\"next_steps\":\"Retry in a few minutes and verify that \`$owner_name\` is running.\nTroubleshoot $owner_kind Warning Events for \`$owner_name\`\"}"
fi

if [[ $messages =~ "Liveness probe failed" || $messages =~ "Liveness probe errored" ]]; then
    issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` is restarting\",\"details\":\"$messages\",\"next_steps\":\"Check Liveliness Probe Configuration for $owner_kind \`$owner_name\`\"}"

fi

if [[ $messages =~ "Readiness probe errored" || $messages =~ "Readiness probe failed" ]]; then
    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` is unable to start\",\"details\":\"$messages\",\"next_steps\":\"Check Readiness Probe Configuration for $owner_kind \`$owner_name\`\"}"
fi

if [[ $messages =~ "PodFailed" ]]; then
    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has failed pods\",\"details\":\"$messages\",\"next_steps\":\"Check Readiness Probe Configuration for $owner_kind \`$owner_name\`\"}"
fi

if [[ $messages =~ "ImagePullBackOff" || $messages =~ "Back-off pulling image" || $messages =~ "ErrImagePull" ]]; then
    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has image access issues\",\"details\":\"$messages\",\"next_steps\":\"List Images and Tags for Every Container in Failed Pods for Namespace \`$NAMESPACE\`\nList ImagePullBackoff Events and Test Path and Tags for Namespace \`$NAMESPACE\`\"}"
fi

if [[ $messages =~ "Back-off restarting failed container" ]]; then
    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` has failing containers\",\"details\":\"$messages\",\"next_steps\":\"Check Log for $owner_kind \`$owner_name\`\nTroubleshoot Warning Events for $owner_kind \`$owner_name\`\"}"
fi


if [[ $messages =~ "forbidden: failed quota" || $messages =~ "forbidden: exceeded quota" ]]; then
    issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` has resources that cannot be scheduled\",\"details\":\"$messages\",\"next_steps\":\"Check Resource Quota Utilization in Namepace \`${NAMESPACE}\`\"}"
fi

if [[ $messages =~ "No preemption victims found for incoming pod" || $messages =~ "Insufficient cpu" ]]; then
    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` cannot be scheduled - not enough cluster resources.\",\"details\":\"$messages\",\"next_steps\":\"Not enough node resources available to schedule pods. Escalate this issue to your cluster owner.\nIncrease Node Count in Cluster\nCheck for Quota Errors\"}"

fi

if [[ $messages =~ "max node group size reached" ]]; then
    issue_details="{\"severity\":\"2\",\"title\":\"$owner_kind \`$owner_name\` cannot be scheduled - cannot increase cluster size.\",\"details\":\"$messages\",\"next_steps\":\"Not enough node resources available to schedule pods. Escalate this issue to your cluster owner.\nIncrease Max Node Group Size in Cluster\"}"
fi

if [[ $messages =~ "Health check failed after" ]]; then
    issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` health check failed.\",\"details\":\"$messages\",\"next_steps\":\"Check $owner_kind \`$owner_name\` Health\"}"
fi

if [[ $messages =~ "Deployment does not have minimum availability" ]]; then
    issue_details="{\"severity\":\"3\",\"title\":\"$owner_kind \`$owner_name\` is not available.\",\"details\":\"$messages\",\"next_steps\":\"Troubleshoot Deployment Warning Events for \`$owner_name\`\"}"
fi


# Outputting recommendations as JSON
if [ -n "$issue_details" ]; then
    echo "Issue details:"
    echo "$issue_details" | jq .
else
    echo "No issues found."
fi