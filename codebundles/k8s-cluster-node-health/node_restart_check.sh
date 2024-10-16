#!/bin/bash

context=$CONTEXT

# Set the time interval (e.g., 24 hours)
interval=$INTERVAL

# Get the current date and time (ISO 8601 format)
CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Calculate the time for the start of the interval using GNU date
START_DATE=$(date -u -d "$interval ago" +"%Y-%m-%dT%H:%M:%SZ")

# Fetch all node-related events within the time range
kubectl get events -A --context $context \
  --field-selector involvedObject.kind=Node \
  --output=jsonpath='{range .items[*]}{.lastTimestamp}{" "}{.involvedObject.name}{" "}{.reason}{" "}{.message}{"\n"}{end}' \
  | awk -v start="$START_DATE" -v end="$CURRENT_DATE" '$1 >= start && $1 <= end' \
  | grep -E "(Preempt|Shutdown|Drain|Termination|Removed|Deleted|NodeReady|RegisteredNode)" \
  | sort | uniq > node_events.txt

# Function to check if a node is preemptible/spot based on annotations or labels
check_preemptible_node() {
    node=$1
    # Check for the presence of the preemptible/spot-related annotations or labels
    is_preemptible=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.cloud\.google\.com/gke-preemptible}' 2>/dev/null)
    is_spot=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/capacityType}' 2>/dev/null)
    is_azure_spot=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.kubernetes\.azure\.com/scalesetpriority}' 2>/dev/null)

    if [[ "$is_preemptible" == "true" ]]; then
        echo "Preemptible (GCP)"
    elif [[ "$is_spot" == "SPOT" ]]; then
        echo "Spot (AWS)"
    elif [[ "$is_azure_spot" == "spot" ]]; then
        echo "Spot (Azure)"
    else
        echo "Unidentified/Unplanned"
    fi
}

# Track unique nodes started and stopped
declare -A nodes_started
declare -A nodes_stopped
declare -A total_node_events

# Read the node events and summarize by node
while read -r line; do
    node=$(echo "$line" | awk '{print $2}')
    preempt_status=$(check_preemptible_node "$node")
    
    # Print node summary
    if [[ ! "$current_node" == "$node" ]]; then
        if [[ -n "$current_node" ]]; then
            echo ""  # Empty line between different nodes
        fi
        echo "Node: $node"
        echo "Type: $preempt_status"
        echo "Activities:"
        current_node="$node"
    fi

    # Determine if the node was started or stopped
    if echo "$line" | grep -qE "(NodeReady|RegisteredNode)"; then
        nodes_started["$node"]=1
    elif echo "$line" | grep -qE "(Shutdown|Preempt|Termination|Removed)"; then
        nodes_stopped["$node"]=1
    fi
    
    # Print the event details for the node
    echo "  - $line"
done < node_events.txt

# Summary of unique nodes started and stopped
unique_nodes_started=${#nodes_started[@]}
unique_nodes_stopped=${#nodes_stopped[@]}
total_node_events=$((unique_nodes_started + unique_nodes_stopped))

echo ""
echo "Summary:"
echo "Unique nodes started: $unique_nodes_started"
echo "Unique nodes stopped: $unique_nodes_stopped"
echo "Total start/stop events: $total_node_events"