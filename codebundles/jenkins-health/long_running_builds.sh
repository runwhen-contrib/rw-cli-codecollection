#!/bin/bash
# set -x
# Check if required environment variables are set
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

if [ -z "${JENKINS_URL}" ] || [ -z "${JENKINS_USERNAME}" ] || [ -z "${JENKINS_TOKEN}" ]; then
    echo "Please set JENKINS_URL, JENKINS_USERNAME, and JENKINS_TOKEN environment variables."
    exit 1
fi

convert_to_minutes() {
    local time_str=$1
    # Convert to lowercase and remove any spaces
    time_str=$(echo "$time_str" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    
    # Extract number using regex
    local number=$(echo "$time_str" | grep -o '^[0-9]\+')
    
    # Extract unit by removing the number
    local unit=$(echo "$time_str" | sed 's/^[0-9]\+//')

    case $unit in
        m|min|minute|minutes)
            if [ "$number" -lt 0 ] || [ "$number" -gt 59 ]; then
                echo "Minutes should be between 0-59" >&2
                exit 1
            fi
            echo $number ;;
        h|hr|hour|hours)
            if [ "$number" -lt 0 ] || [ "$number" -gt 23 ]; then
                echo "Hours should be between 0-23" >&2
                exit 1
            fi
            echo $((number * 60)) ;;
        d|day|days)
            echo $((number * 1440)) ;;
        *)
            echo "Invalid time format. Please use formats like '5m', '2h', '1d' or '5min', '2hours', '1day'" >&2
            echo "Minutes should be between 0-59" >&2
            echo "Hours should be between 0-23" >&2
            exit 1
            ;;
    esac
}

# Check if threshold parameter is provided
if [ -z "$1" ]; then
    echo "Please provide time threshold (e.g., ./long_running_jobs.sh 5m or 2h or 1d)"
    exit 1
fi

THRESHOLD_MINUTES=$(convert_to_minutes "$1")

# Authentication string for curl
AUTH_HEADER="${JENKINS_USERNAME}:${JENKINS_TOKEN}"

# Get current timestamp in milliseconds
current_time=$(date +%s%3N)

# Fetch Jenkins data and process it using jq to find long running jobs
jenkins_data=$(curl -s -u "${AUTH_HEADER}" "${JENKINS_URL}/api/json?depth=2")

# Validate if Jenkins data was retrieved successfully
if [ -z "$jenkins_data" ]; then
    echo "Failed to fetch data from Jenkins. Please check your credentials or URL."
    exit 1
fi

# Process the data using jq to find long running jobs and output as JSON
echo "$jenkins_data" | jq --arg threshold "$THRESHOLD_MINUTES" --arg current "$current_time" '
{
  "timestamp": ($current | tonumber),
  "threshold": ($threshold | tonumber),
  "long_running_jobs": [
    .jobs[] | 
    select(.lastBuild != null and .lastBuild.building) |
    {
      "job_name": .name,
      "build_number": .lastBuild.number,
      "node": (if .lastBuild.builtOn == "" then "Built-in Node" else .lastBuild.builtOn end),
      "start_time": .lastBuild.timestamp,
      "duration_minutes": (((($current | tonumber) - .lastBuild.timestamp) / 1000 / 60) | floor),
      "url": .lastBuild.url
    } | 
    select(.duration_minutes >= ($threshold | tonumber))
  ]
}' | jq '.long_running_jobs[] |= . + {
  "duration": ((.duration_minutes | tostring) + "m")
}' | jq 'walk(
  if type == "object" and has("duration") then
    .duration = (if .duration_minutes >= 1440 then
      ((.duration_minutes / 1440) | floor | tostring) + "d " +
      (((.duration_minutes % 1440) / 60) | floor | tostring) + "h " +
      (.duration_minutes % 60 | tostring) + "m"
    elif .duration_minutes >= 60 then
      ((.duration_minutes / 60) | floor | tostring) + "h " +
      (.duration_minutes % 60 | tostring) + "m"
    else
      (.duration_minutes | tostring) + "m"
    end | sub("\\s+$"; ""))
  else
    .
  end
)' 
