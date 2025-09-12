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

# Consolidate probe failures to avoid duplicate issues
probe_issues_found=false

if echo "$messages" | grep -q "Startup probe failed\|Readiness probe errored\|Readiness probe failed"; then
    # Determine which probe types are failing
    probe_types=""
    next_steps=""
    
    if echo "$messages" | grep -q "Startup probe failed"; then
        probe_types="startup"
        next_steps="Check Deployment Logs\nReview Startup Probe Configuration\nIncrease Startup Probe Timeout and Threshold"
    fi
    
    if echo "$messages" | grep -q "Readiness probe errored\|Readiness probe failed"; then
        if [ -n "$probe_types" ]; then
            probe_types="$probe_types and readiness"
            next_steps="$next_steps\nCheck Readiness Probe Configuration"
        else
            probe_types="readiness"
            next_steps="Check Readiness Probe Configuration"
        fi
    fi
    
    # Add resource constraint check for any probe failure
    next_steps="$next_steps\nIdentify Resource Constrained Pods In Namespace \`$NAMESPACE\`"
    
    add_issue "2" "$(echo $probe_types | sed 's/^./\U&/') probe failures" "$messages" "$next_steps"
    probe_issues_found=true
fi

if echo "$messages" | grep -q "Liveness probe failed\|Liveness probe errored" && [ "$probe_issues_found" = false ]; then
    add_issue "3" "Liveness probe failure" "$messages" "Check Liveliness Probe Configuration"
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

if echo "$messages" | grep -q "FailedScheduling"; then
    add_issue "2" "Pod scheduling failures" "$messages" "Check node resources and availability\\nReview resource requests and limits\\nInspect node selectors and affinity rules\\nVerify PersistentVolume availability"
fi

if echo "$messages" | grep -q "FailedMount"; then
    add_issue "2" "Volume mount failures" "$messages" "Check PersistentVolume and PersistentVolumeClaim status\\nVerify storage class configuration\\nInspect volume permissions and node access\\nReview ConfigMap and Secret availability"
fi

if echo "$messages" | grep -q "FailedPull\|ErrImagePull\|ImagePullBackOff"; then
    add_issue "2" "Image pull failures" "$messages" "Verify container image exists in registry\\nCheck image pull secrets and registry authentication\\nReview image tag and repository configuration\\nInspect network connectivity to registry"
fi

if echo "$messages" | grep -q "CrashLoopBackOff"; then
    add_issue "1" "Container crash loop" "$messages" "Check container logs for crash details\\nReview application startup configuration\\nVerify resource limits are sufficient\\nInspect health probe configuration"
fi

if echo "$messages" | grep -q "Evicted\|EvictionThresholdMet"; then
    add_issue "3" "Pod eviction events" "$messages" "Check node resource pressure (memory, disk)\\nReview resource requests and limits\\nInspect node conditions and available resources\\nConsider adjusting resource allocation"
fi

if echo "$messages" | grep -q "BackOff\|Error syncing pod"; then
    add_issue "3" "Pod sync/backoff issues" "$messages" "Check kubelet logs on affected nodes\\nReview pod specification for errors\\nInspect resource constraints and dependencies\\nVerify container runtime health"
fi

if echo "$messages" | grep -q "NetworkNotReady\|CNI"; then
    add_issue "2" "Network configuration issues" "$messages" "Check CNI plugin status and configuration\\nVerify network policies and connectivity\\nInspect node network interface configuration\\nReview DNS and service discovery"
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
    # Generate a more descriptive title based on the actual event messages
    title="Warning events detected"
    
    # Try to extract specific error types from messages for better titles
    if echo "$messages" | grep -qi "failed\|error\|timeout"; then
        if echo "$messages" | grep -qi "pull\|image"; then
            title="Image pull issues"
        elif echo "$messages" | grep -qi "mount\|volume"; then
            title="Volume mount issues"
        elif echo "$messages" | grep -qi "network\|dns\|connection"; then
            title="Network connectivity issues"
        elif echo "$messages" | grep -qi "resource\|memory\|cpu"; then
            title="Resource constraint issues"
        elif echo "$messages" | grep -qi "permission\|rbac\|unauthorized"; then
            title="Permission/authorization issues"
        elif echo "$messages" | grep -qi "scheduling\|node"; then
            title="Pod scheduling issues"
        else
            title="Application or configuration issues"
        fi
    elif echo "$messages" | grep -qi "backoff\|crashloop"; then
        title="Pod crash/restart issues"
    elif echo "$messages" | grep -qi "evict\|preempt"; then
        title="Pod eviction issues"
    elif echo "$messages" | grep -qi "scale\|replica"; then
        title="Scaling issues"
    elif echo "$messages" | grep -qi "unhealthy\|health"; then
        title="Health check issues"
    fi
    
    echo "[{\"severity\":\"3\",\"title\":\"$title\",\"details\":\"$messages\",\"next_steps\":\"Review event messages for specific error details\\nCheck pod status and logs\\nInvestigate underlying cause based on event type\\nEscalate to service owner if issue persists\"}]" | jq .
fi
