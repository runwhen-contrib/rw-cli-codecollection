#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script fetches and processes Kubernetes warning events,
# handling time parsing robustly and avoiding jq syntax issues in Robot Framework.
# -----------------------------------------------------------------------------

# Function to extract numeric value from time duration
parse_event_age() {
    local time_input="$1"
    
    # If it's just a number, return it as-is (minutes)
    if [[ "$time_input" =~ ^[0-9]+$ ]]; then
        echo "$time_input"
        return
    fi
    
    # If it has 'm' suffix, extract the number
    if [[ "$time_input" =~ ^([0-9]+)m$ ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # If it has 'h' suffix, convert to minutes
    if [[ "$time_input" =~ ^([0-9]+)h$ ]]; then
        echo $((${BASH_REMATCH[1]} * 60))
        return
    fi
    
    # Default fallback
    echo "30"
}

# Check if required environment variables are set
if [[ -z "$KUBERNETES_DISTRIBUTION_BINARY" ]]; then
    echo "Error: KUBERNETES_DISTRIBUTION_BINARY is not set" >&2
    exit 1
fi

if [[ -z "$CONTEXT" ]]; then
    echo "Error: CONTEXT is not set" >&2
    exit 1
fi

if [[ -z "$NAMESPACE" ]]; then
    echo "Error: NAMESPACE is not set" >&2
    exit 1
fi

# Parse RW_LOOKBACK_WINDOW - default to 30m if not set (aligned with other runbook tasks)
EVENT_AGE_MINUTES=$(parse_event_age "${RW_LOOKBACK_WINDOW:-30m}")

# Create temporary directory under current working directory
TEMP_DIR="./temp_warning_events_$$_$(date +%s)"
mkdir -p "$TEMP_DIR"
WARNING_EVENTS_FILE="$TEMP_DIR/warning_events.json"

# Get warning events
if ! $KUBERNETES_DISTRIBUTION_BINARY get events \
    --field-selector type=Warning \
    --context "$CONTEXT" \
    -n "$NAMESPACE" \
    -o json > "$WARNING_EVENTS_FILE"; then
    echo "Error: Failed to fetch warning events" >&2
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Get current pods to filter out events for non-existent pods
CURRENT_PODS_FILE="$TEMP_DIR/current_pods.json"
if ! $KUBERNETES_DISTRIBUTION_BINARY get pods \
    --context "$CONTEXT" \
    -n "$NAMESPACE" \
    -o json > "$CURRENT_PODS_FILE"; then
    echo "Warning: Failed to fetch current pods, proceeding without pod filtering" >&2
    echo "[]" > "$CURRENT_PODS_FILE"
fi

# Process events with jq, filtering out events for non-existent pods
jq -r --argjson event_age_minutes "$EVENT_AGE_MINUTES" --slurpfile current_pods "$CURRENT_PODS_FILE" '
# Create a set of current pod names for filtering
($current_pods[0].items // [] | map(.metadata.name) | unique) as $existing_pods |
[.items[] | 
  # Filter out events with unknown or missing object names
  select(
    .involvedObject.name != null and 
    .involvedObject.name != "" and 
    .involvedObject.name != "Unknown" and
    .involvedObject.kind != null and 
    .involvedObject.kind != ""
  ) |
  # Filter out pod events for non-existent pods
  select(
    if .involvedObject.kind == "Pod" then
      (.involvedObject.name as $pod_name | $existing_pods | index($pod_name) != null)
    else
      true
    end
  ) | {
    namespace: .involvedObject.namespace,
    kind: .involvedObject.kind,
    baseName: (
        (if .involvedObject.kind == "Pod" then 
            (.involvedObject.name | split("-")[:-1] | join("-"))
         else
            .involvedObject.name
        end) // ""
    ),
    count: .count,
    firstTimestamp: (.firstTimestamp // ""),
    lastTimestamp: (.lastTimestamp // ""),
    reason: .reason,
    message: .message
}] 
| group_by(.namespace, .kind, .baseName) 
| map({
    object: (.[0].namespace + "/" + .[0].kind + "/" + .[0].baseName),
    total_events: (reduce .[] as $event (0; . + $event.count)),
    summary_messages: (map(.message) | unique | join("; ")),
    oldest_timestamp: (map(select(.firstTimestamp != null and .firstTimestamp != "").firstTimestamp) | sort | first),
    most_recent_timestamp: (map(select(.lastTimestamp != null and .lastTimestamp != "").lastTimestamp) | sort | last)
}) 
| map(select(
    .most_recent_timestamp != null and 
    .most_recent_timestamp != "" and
    (now - ((.most_recent_timestamp | fromdateiso8601)))/60 <= $event_age_minutes
))' "$WARNING_EVENTS_FILE"

# Cleanup
rm -rf "$TEMP_DIR" 