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

if [ -z "$GITHUB_ORG" ]; then
    error_exit "GITHUB_ORG is required"
fi

# Default values
LOOKBACK_DAYS=${FAILURE_LOOKBACK_DAYS:-7}
FAILURE_THRESHOLD=${ORG_FAILURE_THRESHOLD:-10}

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

echo "Checking organization-wide workflow health across specified organizations..." >&2

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

# Get all repositories in the organization
repos_json=$(perform_curl "https://api.github.com/orgs/$GITHUB_ORG/repos?per_page=100&sort=updated")

# Check if the response contains repositories
if ! echo "$repos_json" | jq -e '.' >/dev/null || [ "$(echo "$repos_json" | jq 'length')" -eq 0 ]; then
    error_exit "Failed to fetch repositories or no repositories found for organization $GITHUB_ORG"
fi

# Initialize counters
total_repos=0
repos_with_failures=0
total_failures=0
repos_with_failures_list=()

# Process each repository
echo "$repos_json" | jq -r '.[].full_name' | while read -r repo_name; do
    total_repos=$((total_repos + 1))
    echo "Checking repository: $repo_name" >&2
    
    # Get workflow runs for this repository
    runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?created=>$date_threshold&per_page=100" || echo '{"workflow_runs":[]}')
    
    # Count failures for this repository
    repo_failures=$(echo "$runs_json" | jq '[.workflow_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")] | length')
    
    if [ "$repo_failures" -gt 0 ]; then
        repos_with_failures=$((repos_with_failures + 1))
        total_failures=$((total_failures + repo_failures))
        repos_with_failures_list+=("$repo_name")
        echo "Repository $repo_name has $repo_failures failures" >&2
    fi
    
    # Rate limiting protection
    sleep 0.2
done

# Calculate health score
if [ "$total_repos" -gt 0 ]; then
    health_score=$(echo "scale=3; (($total_repos - $repos_with_failures) / $total_repos)" | bc -l)
else
    health_score=1.0
fi

# Convert array to JSON format
repos_failures_json=$(printf '%s\n' "${repos_with_failures_list[@]}" | jq -R . | jq -s .)

# Create the final JSON output
cat << EOF
{
    "organization": "$GITHUB_ORG",
    "lookback_days": $LOOKBACK_DAYS,
    "total_repositories": $total_repos,
    "repositories_with_failures": $repos_failures_json,
    "repositories_with_failures_count": $repos_with_failures,
    "total_failures": $total_failures,
    "health_score": $health_score,
    "threshold_exceeded": $([ "$total_failures" -gt "$FAILURE_THRESHOLD" ] && echo "true" || echo "false"),
    "failure_threshold": $FAILURE_THRESHOLD,
    "date_threshold": "$date_threshold"
}
EOF 