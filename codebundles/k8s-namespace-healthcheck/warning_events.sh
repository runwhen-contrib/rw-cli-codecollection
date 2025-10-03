#!/bin/bash

# -----------------------------------------------------------------------------
# Script Information and Metadata
# -----------------------------------------------------------------------------
# Author: @stewartshea
# Description: This script fetches and processes Kubernetes warning events,
# handling time parsing robustly and avoiding jq syntax issues in Robot Framework.
# -----------------------------------------------------------------------------

# Function to extract numeric value from time duration
# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

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
    # Extract timestamp from log context

    log_timestamp=$(extract_log_timestamp "$0")

    echo "Error: KUBERNETES_DISTRIBUTION_BINARY is not set (detected at $log_timestamp)" >&2
    exit 1
fi

if [[ -z "$CONTEXT" ]]; then
    # Extract timestamp from log context

    log_timestamp=$(extract_log_timestamp "$0")

    echo "Error: CONTEXT is not set (detected at $log_timestamp)" >&2
    exit 1
fi

if [[ -z "$NAMESPACE" ]]; then
    # Extract timestamp from log context

    log_timestamp=$(extract_log_timestamp "$0")

    echo "Error: NAMESPACE is not set (detected at $log_timestamp)" >&2
    exit 1
fi

# Parse EVENT_AGE - default to 5 if not set (aligned with SLI frequency)
EVENT_AGE_MINUTES=$(parse_event_age "${EVENT_AGE:-5}")

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
    # Extract timestamp from log context

    log_timestamp=$(extract_log_timestamp "$0")

    echo "Error: Failed to fetch warning events (detected at $log_timestamp)" >&2
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