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
MIN_SUCCESS_RATE=${WORKFLOW_SUCCESS_RATE_THRESHOLD:-0.95}

echo "Calculating workflow SLI across specified repositories..." >&2

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize counters
total_workflows=0
successful_workflows=0
failed_workflows=0

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        echo "Processing repository: $repo_name" >&2
        
        # Get workflow runs for this repository
        runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?created=>$date_threshold&per_page=100&status=completed" || echo '{"workflow_runs":[]}')
        
        # Count workflows for this repository
        if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
            repo_total=$(echo "$runs_json" | jq '[.workflow_runs[]] | length')
            repo_successful=$(echo "$runs_json" | jq '[.workflow_runs[] | select(.conclusion == "success")] | length')
            repo_failed=$(echo "$runs_json" | jq '[.workflow_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out")] | length')
            
            total_workflows=$((total_workflows + repo_total))
            successful_workflows=$((successful_workflows + repo_successful))
            failed_workflows=$((failed_workflows + repo_failed))
            
            echo "Repository $repo_name: $repo_total total, $repo_successful successful, $repo_failed failed" >&2
        else
            echo "No workflow runs found or access denied for repository: $repo_name" >&2
        fi
        
        # Rate limiting protection
        sleep 0.2
    fi
done <<< "$repositories"

# Calculate success rate and SLI
if [ "$total_workflows" -gt 0 ]; then
    success_rate=$(echo "scale=4; $successful_workflows / $total_workflows" | bc -l)
    sli_score=$(echo "scale=4; if($success_rate >= $MIN_SUCCESS_RATE) 1.0 else $success_rate" | bc -l)
    
    # Ensure leading zero for JSON compliance
    if [[ "$success_rate" == .* ]]; then
        success_rate="0$success_rate"
    fi
    if [[ "$sli_score" == .* ]]; then
        sli_score="0$sli_score"
    fi
else
    success_rate="1.0"
    sli_score="1.0"
fi

# Determine status
status="good"
if (( $(echo "$success_rate < $MIN_SUCCESS_RATE" | bc -l) )); then
    status="poor"
elif (( $(echo "$success_rate < 0.99" | bc -l) )); then
    status="degraded"
fi

# Create the final JSON output
cat << EOF
{
    "repositories_analyzed": $(echo "$repositories" | jq -R . | jq -s . | jq 'length'),
    "total_workflows": $total_workflows,
    "successful_workflows": $successful_workflows,
    "failed_workflows": $failed_workflows,
    "success_rate": $success_rate,
    "sli_score": $sli_score,
    "threshold": $MIN_SUCCESS_RATE,
    "status": "$status",
    "lookback_days": $LOOKBACK_DAYS,
    "date_threshold": "$date_threshold"
}
EOF