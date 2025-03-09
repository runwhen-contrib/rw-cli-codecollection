#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to handle error messages and exit
function error_exit {
    echo "Error: $1" >&2
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
    cat $RESULT_PATH | eval "$ANALYSIS_COMMAND" >> report.txt
    cat report.txt
else
    error_exit "Result file $RESULT_FILE not found in the artifact."
fi

# Cleanup
echo "Cleaning up downloaded files..."
rm -rf artifact.zip artifact_contents

echo "Script completed successfully."