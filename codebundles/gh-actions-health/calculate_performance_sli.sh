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