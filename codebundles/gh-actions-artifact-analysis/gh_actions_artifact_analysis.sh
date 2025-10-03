#!/bin/bash

# Exit immediately if a command exits with a non-zero status
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

set -e

# Function to handle error messages and exit
function error_exit {
    # Extract timestamp from log context

    log_timestamp=$(extract_log_timestamp "$0")

    echo "Error: $1 (detected at $log_timestamp)" >&2
    exit 1
}

# Build the headers array for curl
HEADERS=()
if [ -n "$GITHUB_TOKEN" ]; then
    HEADERS+=(-H "Authorization: token $GITHUB_TOKEN")
fi

# Function to perform curl requests with error handling
function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

# Get the latest workflow runs from the repository
echo "Fetching latest runs for repo $GITHUB_REPO..."
runs_json=$(perform_curl "https://api.github.com/repos/$GITHUB_REPO/actions/runs")
# Check if the response contains workflow runs
if ! echo "$runs_json" | jq -e '.workflow_runs' >/dev/null; then
    error_exit "Failed to fetch workflow runs. Ensure the repository exists and is accessible."
fi

# Extract workflow runs
workflow_runs=$(echo "$runs_json" | jq '.workflow_runs')

# Get the latest run for the specific workflow (use .path for the workflow file path)
run_data=$(echo "$workflow_runs" | jq -r --arg WORKFLOW_NAME "$WORKFLOW_NAME" '
    sort_by(.created_at) | reverse |
    map(select(.name == $WORKFLOW_NAME)) | .[0]')

run_id=$(echo "$run_data" | jq -r '.id')
conclusion=$(echo "$run_data" | jq -r '.conclusion')
run_date=$(echo "$run_data" | jq -r '.created_at')

# Check if run_id is null or empty
if [ -z "$run_id" ] || [ "$run_id" == "null" ]; then
    error_exit "No runs found for workflow: $WORKFLOW_NAME"
fi

# Check if the job ran successfully
if [ "$conclusion" != "success" ]; then
    error_exit "The workflow run ID $run_id did not complete successfully. Conclusion: $conclusion"
fi

# Convert run_date to timestamp and check if it was within the defined period
current_time=$(date +%s)
run_time=$(date -d "$run_date" +%s)
time_difference=$(( (current_time - run_time) / 3600 ))

if [ "$time_difference" -gt "$PERIOD_HOURS" ]; then
    error_exit "The latest workflow run is older than $PERIOD_HOURS hours. Run date: $run_date"
fi

echo "Latest run for $WORKFLOW_NAME: ID $run_id on $run_date (Completed successfully within the last $PERIOD_HOURS hours)"

# Get the artifacts from the latest run
echo "Fetching artifacts for run ID $run_id..."
artifacts_json=$(perform_curl "https://api.github.com/repos/$GITHUB_REPO/actions/runs/$run_id/artifacts")

# Check if the response contains artifacts
if ! echo "$artifacts_json" | jq -e '.artifacts' >/dev/null; then
    error_exit "Failed to fetch artifacts for run ID $run_id. Check access permissions."
fi

# Extract artifacts
artifacts=$(echo "$artifacts_json" | jq '.artifacts')

artifact_id=$(echo "$artifacts" | jq -r --arg ARTIFACT_NAME "$ARTIFACT_NAME" '
    map(select(.name == $ARTIFACT_NAME)) | .[0]?.id')

if [ -z "$artifact_id" ] || [ "$artifact_id" == "null" ]; then
    error_exit "No artifacts found with the name: $ARTIFACT_NAME"
fi

# Get the download URL for the artifact
artifact_url=$(echo "$artifacts" | jq -r --arg ARTIFACT_ID "$artifact_id" '
    map(select(.id == ($ARTIFACT_ID | tonumber))) | .[0]?.archive_download_url')

if [ -z "$artifact_url" ] || [ "$artifact_url" == "null" ]; then
    error_exit "Failed to get download URL for artifact ID: $artifact_id"
fi

# Download the artifact
echo "Downloading artifact..."
curl -L "${HEADERS[@]}" "$artifact_url" --output artifact.zip || error_exit "Failed to download artifact."

# Verify the artifact was downloaded
if [ ! -f "artifact.zip" ]; then
    error_exit "Artifact download failed, artifact.zip not found."
fi

# Unzip the artifact
echo "Extracting artifact..."
unzip -o artifact.zip -d artifact_contents || error_exit "Failed to unzip the artifact."

# Analyze the result file in the artifact
RESULT_PATH="artifact_contents/$RESULT_FILE"
if [ -f "$RESULT_PATH" ]; then
    echo "Analyzing result file: $RESULT_FILE"
    cat $RESULT_PATH | eval "$ANALYSIS_COMMAND" > report.txt
    cat report.txt
else
    error_exit "Result file $RESULT_FILE not found in the artifact."
fi

# Cleanup
echo "Cleaning up downloaded files..."
rm -rf artifact.zip artifact_contents

echo "Script completed successfully."