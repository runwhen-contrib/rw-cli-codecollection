#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Function to handle error messages and exit
function error_exit {
    echo "Error: $1" >&2
    exit 1
}

# Check required environment variables
if [ -z "$GITHUB_TOKEN" ]; then
    error_exit "GITHUB_TOKEN is required"
fi

# Build the headers array for curl
HEADERS=()
if [ -n "$GITHUB_TOKEN" ]; then
    HEADERS+=(-H "Authorization: token $GITHUB_TOKEN")
fi
HEADERS+=(-H "Accept: application/vnd.github.v3+json")

# Function to perform curl requests with error handling
function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

# Function to get failure details from workflow logs
function get_failure_details {
    local repo_name="$1"
    local run_id="$2"
    local workflow_name="$3"
    
    echo "Fetching failure details for $workflow_name (run $run_id) in $repo_name..." >&2
    
    # Get workflow run jobs
    jobs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs/$run_id/jobs" || echo '{"jobs":[]}')
    
    # Extract failed job details
    local failure_details=""
    if echo "$jobs_json" | jq -e '.jobs' >/dev/null 2>&1; then
        failed_jobs=$(echo "$jobs_json" | jq -r '[.jobs[] | select(.conclusion == "failure" or .conclusion == "cancelled")] | .[0:3]')
        
        if [ "$(echo "$failed_jobs" | jq 'length')" -gt 0 ]; then
            # Get details from first few failed jobs
            while IFS= read -r job; do
                job_name=$(echo "$job" | jq -r '.name')
                job_conclusion=$(echo "$job" | jq -r '.conclusion')
                job_steps=$(echo "$job" | jq -r '[.steps[] | select(.conclusion == "failure")] | .[0:2]')
                
                if [ "$(echo "$job_steps" | jq 'length')" -gt 0 ]; then
                    step_names=$(echo "$job_steps" | jq -r '.[].name' | tr '\n' ', ' | sed 's/,$//')
                    failure_details="$failure_details\nJob: $job_name ($job_conclusion)\nFailed steps: $step_names"
                else
                    failure_details="$failure_details\nJob: $job_name ($job_conclusion)"
                fi
            done <<< $(echo "$failed_jobs" | jq -c '.[]')
        fi
    fi
    
    # If no detailed failure info, provide generic details
    if [ -z "$failure_details" ]; then
        failure_details="No detailed failure information available. Check the workflow logs manually."
    fi
    
    echo "$failure_details"
}

# Function to get repositories to analyze
function get_repositories_to_analyze {
    if [ "$GITHUB_REPOS" = "ALL" ]; then
        if [ -z "$GITHUB_ORGS" ]; then
            error_exit "GITHUB_ORGS is required when GITHUB_REPOS is 'ALL'"
        fi
        
        echo "Getting all repositories for organizations: $GITHUB_ORGS..." >&2
        
        # Initialize repository list
        all_repos=""
        
        # Process each organization
        IFS=',' read -ra ORG_ARRAY <<< "$GITHUB_ORGS"
        for org in "${ORG_ARRAY[@]}"; do
            # Trim whitespace
            org=$(echo "$org" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -n "$org" ]; then
                echo "Fetching repositories for organization: $org" >&2
                
                # Get repositories for this organization
                org_repos_json=$(perform_curl "https://api.github.com/orgs/$org/repos?per_page=100&sort=updated")
                
                # Apply per-org limit if specified
                if [ "${MAX_REPOS_PER_ORG:-0}" -gt 0 ]; then
                    org_repos=$(echo "$org_repos_json" | jq -r ".[0:${MAX_REPOS_PER_ORG}] | .[].full_name")
                else
                    org_repos=$(echo "$org_repos_json" | jq -r '.[].full_name')
                fi
                
                # Add to overall list
                if [ -n "$all_repos" ]; then
                    all_repos="$all_repos"$'\n'"$org_repos"
                else
                    all_repos="$org_repos"
                fi
                
                # Rate limiting protection between organizations
                sleep 0.5
            fi
        done
        
        # Apply overall limit if specified
        if [ "${MAX_REPOS_TO_ANALYZE:-0}" -gt 0 ]; then
            echo "$all_repos" | head -n "${MAX_REPOS_TO_ANALYZE}"
        else
            echo "$all_repos"
        fi
    else
        # Split comma-separated list and output each repository
        echo "$GITHUB_REPOS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
    fi
}

# Default values
LOOKBACK_DAYS=${FAILURE_LOOKBACK_DAYS:-7}

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

echo "Checking workflow failures across specified repositories since $date_threshold..." >&2

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize results array
all_failures="[]"

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        echo "Checking repository: $repo_name" >&2
        
        # Get workflow runs from the repository
        runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?status=failure&created=>$date_threshold&per_page=100" || echo '{"workflow_runs":[]}')
        
        # Check if the response contains workflow runs
        if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            # Extract and format failed workflow runs for this repository
            repo_failures=$(echo "$runs_json" | jq -r --arg repo "$repo_name" '[
                .workflow_runs[] | 
                select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out") |
                {
                    repository: $repo,
                    workflow_name: .name,
                    run_number: .run_number,
                    run_id: .id,
                    conclusion: .conclusion,
                    html_url: .html_url,
                    created_at: .created_at,
                    head_branch: .head_branch,
                    head_sha: (.head_sha // ""),
                    actor: .actor.login,
                    failure_details: "pending"
                }
            ]')
            
            # Enhance with failure details for each failed workflow (limit to avoid too many API calls)
            enhanced_failures="[]"
            failure_count=0
            while IFS= read -r failure; do
                if [ -n "$failure" ] && [ "$failure" != "null" ] && [ $failure_count -lt 5 ]; then
                    run_id=$(echo "$failure" | jq -r '.run_id')
                    workflow_name=$(echo "$failure" | jq -r '.workflow_name')
                    
                    # Get failure details
                    failure_details=$(get_failure_details "$repo_name" "$run_id" "$workflow_name")
                    
                    # Update the failure object with details (safely handle newlines and special chars)
                    enhanced_failure=$(echo "$failure" | jq --arg details "$failure_details" '.failure_details = $details')
                    # Safely add to array by combining arrays
                    enhanced_failures=$(echo "$enhanced_failures [$enhanced_failure]" | jq -s '.[0] + .[1]')
                    
                    failure_count=$((failure_count + 1))
                else
                    # Add without enhanced details to avoid too many API calls
                    enhanced_failures=$(echo "$enhanced_failures [$failure]" | jq -s '.[0] + .[1]')
                fi
            done <<< $(echo "$repo_failures" | jq -c '.[]')
            
            # Merge with all failures
            all_failures=$(echo "$all_failures $enhanced_failures" | jq -s 'add')
        else
            echo "No workflow runs found or access denied for repository: $repo_name" >&2
        fi
        
        # Rate limiting protection
        sleep 0.2
    fi
done <<< "$repositories"

# Output the results
echo "$all_failures" 