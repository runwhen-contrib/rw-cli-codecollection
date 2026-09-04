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
LOOKBACK_DAYS=${SLI_LOOKBACK_DAYS:-7}
MAX_DURATION_MINUTES=${MAX_WORKFLOW_DURATION_MINUTES:-60}

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

echo "Calculating performance SLI across specified repositories since $date_threshold..." >&2

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize aggregated metrics
total_workflows=0
total_duration_seconds=0
long_running_count=0
all_durations=()

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        echo "Processing repository: $repo_name" >&2
        
        # Get completed workflow runs from the repository
        runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?status=completed&created=>$date_threshold&per_page=100" || echo '{"workflow_runs":[]}')
        
        # Check if the response contains workflow runs
        if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            # Process each workflow run
            while IFS= read -r run; do
                if [ -n "$run" ] && [ "$run" != "null" ]; then
                    created_at=$(echo "$run" | jq -r '.created_at')
                    updated_at=$(echo "$run" | jq -r '.updated_at')
                    
                    # Calculate duration in seconds
                    created_timestamp=$(date -d "$created_at" +%s)
                    updated_timestamp=$(date -d "$updated_at" +%s)
                    duration_seconds=$((updated_timestamp - created_timestamp))
                    
                    # Add to aggregated metrics
                    total_workflows=$((total_workflows + 1))
                    total_duration_seconds=$((total_duration_seconds + duration_seconds))
                    all_durations+=($duration_seconds)
                    
                    # Check if it's a long-running workflow
                    duration_minutes=$((duration_seconds / 60))
                    if [ $duration_minutes -gt $MAX_DURATION_MINUTES ]; then
                        long_running_count=$((long_running_count + 1))
                    fi
                fi
            done <<< $(echo "$runs_json" | jq -c '.workflow_runs[]?')
        else
            echo "No workflow runs found or access denied for repository: $repo_name" >&2
        fi
        
        # Rate limiting protection
        sleep 0.2
    fi
done <<< "$repositories"

# Calculate performance metrics
if [ $total_workflows -gt 0 ]; then
    avg_duration_seconds=$((total_duration_seconds / total_workflows))
    avg_duration_minutes=$((avg_duration_seconds / 60))
    
    # Calculate performance score (1.0 if avg duration is under threshold, scaled down if over)
    if [ $avg_duration_minutes -le $MAX_DURATION_MINUTES ]; then
        performance_score="1.0"
    else
        # Scale score down based on how much over the threshold
        excess_ratio=$(echo "scale=2; $avg_duration_minutes / $MAX_DURATION_MINUTES" | bc -l)
        performance_score=$(echo "scale=2; 1.0 / $excess_ratio" | bc -l)
        # Cap minimum score at 0.1
        performance_score=$(echo "if ($performance_score < 0.1) 0.1 else $performance_score" | bc -l)
        
        # Ensure leading zero for JSON compliance
        if [[ "$performance_score" == .* ]]; then
            performance_score="0$performance_score"
        fi
    fi
else
    avg_duration_seconds=0
    avg_duration_minutes=0
    performance_score="1.0"
fi

# Output the results as JSON
cat << EOF
{
    "performance_score": $performance_score,
    "total_workflows": $total_workflows,
    "avg_duration_seconds": $avg_duration_seconds,
    "avg_duration_minutes": $avg_duration_minutes,
    "long_running_count": $long_running_count,
    "max_duration_threshold_minutes": $MAX_DURATION_MINUTES,
    "repositories_analyzed": $(echo "$repositories" | wc -l),
    "lookback_days": $LOOKBACK_DAYS
}
EOF