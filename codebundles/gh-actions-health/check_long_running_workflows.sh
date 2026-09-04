#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e
source "$(dirname "$0")/_github_auth.sh"

# Function to handle error messages and exit

# Function to perform curl requests with error handling
function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

# Default values
MAX_DURATION_MINUTES=${MAX_WORKFLOW_DURATION_MINUTES:-60}

echo "Checking for long-running workflows across specified repositories..." >&2

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Get current time for calculations
current_time=$(date +%s)

# Initialize results array
all_long_running="[]"

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        echo "Checking repository: $repo_name" >&2
        
        # Get currently running workflows
        running_runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?status=in_progress&per_page=100" || echo '{"workflow_runs":[]}')
        
        # Check if the response contains workflow runs
        if echo "$running_runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            # Process running workflows and check duration
            long_running=$(echo "$running_runs_json" | jq -r --argjson max_duration "$MAX_DURATION_MINUTES" --argjson current_time "$current_time" --arg repo "$repo_name" '[
                .workflow_runs[] | 
                select(.status == "in_progress") |
                . as $run |
                ($run.created_at | fromdateiso8601) as $start_time |
                (($current_time - $start_time) / 60) as $duration_minutes |
                select($duration_minutes > $max_duration) |
                {
                    repository: $repo,
                    workflow_name: .name,
                    run_number: .run_number,
                    duration_minutes: ($duration_minutes | floor),
                    html_url: .html_url,
                    created_at: .created_at,
                    head_branch: .head_branch,
                    actor: .actor.login,
                    status: .status
                }
            ]')
            
            # Also check recently completed workflows that took too long
            completed_runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?status=completed&per_page=50" || echo '{"workflow_runs":[]}')
            
            # Process completed workflows for duration analysis
            long_completed=$(echo "$completed_runs_json" | jq -r --argjson max_duration "$MAX_DURATION_MINUTES" --arg repo "$repo_name" '[
                .workflow_runs[] |
                select(.conclusion != null and .updated_at != null and .created_at != null) |
                . as $run |
                (($run.updated_at | fromdateiso8601) - ($run.created_at | fromdateiso8601)) / 60 as $duration_minutes |
                select($duration_minutes > $max_duration) |
                {
                    repository: $repo,
                    workflow_name: .name,
                    run_number: .run_number,
                    duration_minutes: ($duration_minutes | floor),
                    html_url: .html_url,
                    created_at: .created_at,
                    completed_at: .updated_at,
                    conclusion: .conclusion,
                    head_branch: .head_branch,
                    actor: .actor.login,
                    status: "completed_long_duration"
                }
            ] | .[0:3]')  # Limit to 3 most recent per repo
            
            # Combine results for this repository
            repo_combined=$(echo "$long_running $long_completed" | jq -s 'add')
            all_long_running=$(echo "$all_long_running $repo_combined" | jq -s 'add')
        else
            echo "No workflow runs found or access denied for repository: $repo_name" >&2
        fi
        
        # Rate limiting protection
        sleep 0.2
    fi
done <<< "$repositories"

# Output the results
echo "$all_long_running" 