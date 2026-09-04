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
LOOKBACK_DAYS=${FAILURE_LOOKBACK_DAYS:-7}
FAILURE_THRESHOLD=${REPO_FAILURE_THRESHOLD:-10}

echo "Checking repository health summary across specified repositories..." >&2

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize counters
total_repos=0
repos_with_failures=0
total_failures=0
repos_with_failures_list=()
repos_analyzed_list=()

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        total_repos=$((total_repos + 1))
        repos_analyzed_list+=("$repo_name")
        echo "Checking repository: $repo_name" >&2
        
        # Get workflow runs for this repository
        runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?created=>$date_threshold&per_page=100" || echo '{"workflow_runs":[]}')
        
        # Count failures for this repository
        if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            repo_failures=$(echo "$runs_json" | jq '[.workflow_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")] | length')
            
            if [ "$repo_failures" -gt 0 ]; then
                repos_with_failures=$((repos_with_failures + 1))
                total_failures=$((total_failures + repo_failures))
                repos_with_failures_list+=("$repo_name")
                echo "Repository $repo_name has $repo_failures failures" >&2
        else
            echo "No workflow runs found or access denied for repository: $repo_name" >&2
        fi
        
        # Rate limiting protection
        sleep 0.2
    fi
    fi
done <<< "$repositories"

# Calculate health score
if [ "$total_repos" -gt 0 ]; then
    health_score=$(echo "scale=3; (($total_repos - $repos_with_failures) / $total_repos)" | bc -l)
else
    health_score=1.0
fi

# Convert arrays to JSON format
repos_failures_json=$(printf '%s\n' "${repos_with_failures_list[@]}" | jq -R . | jq -s .)
repos_analyzed_json=$(printf '%s\n' "${repos_analyzed_list[@]}" | jq -R . | jq -s .)

# Create the final JSON output
cat << EOF
{
    "repositories_analyzed": $repos_analyzed_json,
    "total_repositories": $total_repos,
    "repositories_with_failures": $repos_failures_json,
    "repositories_with_failures_count": $repos_with_failures,
    "total_failures": $total_failures,
    "overall_health_score": $health_score,
    "threshold_exceeded": $([ "$total_failures" -gt "$FAILURE_THRESHOLD" ] && echo "true" || echo "false"),
    "failure_threshold": $FAILURE_THRESHOLD,
    "lookback_days": $LOOKBACK_DAYS,
    "date_threshold": "$date_threshold"
}
EOF 