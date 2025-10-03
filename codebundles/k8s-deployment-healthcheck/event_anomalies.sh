#!/bin/bash

# Assuming environment variables are already exported and available

# Command to get Kubernetes events in JSON format
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

EVENTS_JSON=$(${KUBERNETES_DISTRIBUTION_BINARY} get events --context ${CONTEXT} -n ${NAMESPACE} -o json)

# Use jq to process the JSON, skipping events without valid timestamps
PROCESSED_EVENTS=$(echo "${EVENTS_JSON}" | jq --arg DEPLOYMENT_NAME "${DEPLOYMENT_NAME}" '
  [ .items[]
    | select(
        .type != "Warning"
        and (.involvedObject.kind | test("Deployment|ReplicaSet|Pod"))
        and (.involvedObject.name | contains($DEPLOYMENT_NAME))
        and (.firstTimestamp | fromdateiso8601? // empty) and (.lastTimestamp | fromdateiso8601? // empty)
        # Filter out events with unknown or missing object names
        and .involvedObject.name != null 
        and .involvedObject.name != "" 
        and .involvedObject.name != "Unknown"
        and .involvedObject.kind != null 
        and .involvedObject.kind != ""
      )
    | {
        kind: .involvedObject.kind,
        count: .count,
        name: .involvedObject.name,
        reason: .reason,
        message: .message,
        firstTimestamp: .firstTimestamp,
        lastTimestamp: .lastTimestamp,
        duration: (
          if (((.lastTimestamp | fromdateiso8601) - (.firstTimestamp | fromdateiso8601)) == 0)
          then 1
          else (((.lastTimestamp | fromdateiso8601) - (.firstTimestamp | fromdateiso8601)) / 60)
          end
        )
      }
  ]
  | group_by([.kind, .name])
  | map({
      kind: .[0].kind,
      name: .[0].name,
      count: (map(.count) | add),
      reasons: (map(.reason) | unique),
      messages: (map(.message) | unique),
      average_events_per_minute: (
        if .[0].duration == 1
        then 1
        else ((map(.count) | add) / .[0].duration)
        end
      ),
      firstTimestamp: (map(.firstTimestamp | fromdateiso8601) | sort | .[0] | todateiso8601),
      lastTimestamp: (map(.lastTimestamp | fromdateiso8601) | sort | reverse | .[0] | todateiso8601)
    })
')

echo "${PROCESSED_EVENTS}"
