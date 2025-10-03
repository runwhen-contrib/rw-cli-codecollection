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

# Default values
LOOKBACK_DAYS=${SLI_LOOKBACK_DAYS:-7}
FAILURE_THRESHOLD=${REPO_FAILURE_THRESHOLD:-10}

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

echo "Calculating organization health SLI across specified organizations since $date_threshold..." >&2

# Process organizations
if [ -z "$GITHUB_ORGS" ]; then
    echo "No organizations specified - using default perfect health score" >&2
    cat << EOF
{
    "health_score": 1.0,
    "total_organizations": 0,
    "total_repos": 0,
    "failing_repos": 0,
    "total_workflows": 0,
    "failed_workflows": 0
}
EOF
    exit 0
fi

# Initialize aggregated metrics
total_orgs=0
total_repos=0
failing_repos=0
total_workflows=0
failed_workflows=0

# Process each organization
IFS=',' read -ra ORG_ARRAY <<< "$GITHUB_ORGS"
for org in "${ORG_ARRAY[@]}"; do
    # Trim whitespace
    org=$(echo "$org" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$org" ]; then
        echo "Processing organization: $org" >&2
        total_orgs=$((total_orgs + 1))
        
        # Get repositories for this organization
        repos_json=$(perform_curl "https://api.github.com/orgs/$org/repos?per_page=100&sort=updated")
        
        if echo "$repos_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
            org_repos=$(echo "$repos_json" | jq -r '.[].full_name')
            
            while IFS= read -r repo_name; do
                if [ -n "$repo_name" ]; then
                    total_repos=$((total_repos + 1))
                    
                    # Get workflow runs for this repository
                    runs_json=$(perform_curl "https://api.github.com/repos/$repo_name/actions/runs?created=>$date_threshold&per_page=100" || echo '{"workflow_runs":[]}')
                    
                    if echo "$runs_json" | jq -e '.workflow_runs' >/dev/null 2>&1; then
                        repo_total_workflows=$(echo "$runs_json" | jq '.workflow_runs | length')
                        repo_failed_workflows=$(echo "$runs_json" | jq '[.workflow_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled")] | length')
                        
                        total_workflows=$((total_workflows + repo_total_workflows))
                        failed_workflows=$((failed_workflows + repo_failed_workflows))
                        
                        # Check if this repo has high failure rate
                        if [ $repo_total_workflows -gt 0 ]; then
                            failure_percentage=$(echo "scale=2; ($repo_failed_workflows * 100) / $repo_total_workflows" | bc -l)
                            if (( $(echo "$failure_percentage > $FAILURE_THRESHOLD" | bc -l) )); then
                                failing_repos=$((failing_repos + 1))
                            fi
                        fi
                    fi
                    
                    # Rate limiting protection
                    sleep 0.1
                fi
            done <<< "$org_repos"
        else
            echo "No repositories found or access denied for organization: $org" >&2
        fi
        
        # Rate limiting protection between organizations
        sleep 0.5
    fi
done

# Calculate health score
if [ $total_repos -eq 0 ]; then
    health_score="1.0"
else
    # Health score based on:
    # - Repository failure rate: percentage of repos with high failure rates
    # - Overall workflow success rate
    
    repo_failure_rate=$(echo "scale=4; $failing_repos / $total_repos" | bc -l)
    
    if [ $total_workflows -gt 0 ]; then
        workflow_success_rate=$(echo "scale=4; ($total_workflows - $failed_workflows) / $total_workflows" | bc -l)
    else
        workflow_success_rate="1.0"
    fi
    
    # Combine both factors (60% workflow success, 40% repo health)
    health_score=$(echo "scale=4; ($workflow_success_rate * 0.6) + ((1.0 - $repo_failure_rate) * 0.4)" | bc -l)
    
    # Ensure leading zero for JSON compliance
    if [[ "$health_score" == .* ]]; then
        health_score="0$health_score"
    fi
fi

# Output the results as JSON
cat << EOF
{
    "health_score": $health_score,
    "total_organizations": $total_orgs,
    "total_repos": $total_repos,
    "failing_repos": $failing_repos,
    "total_workflows": $total_workflows,
    "failed_workflows": $failed_workflows,
    "lookback_days": $LOOKBACK_DAYS,
    "failure_threshold_percent": $FAILURE_THRESHOLD
}
EOF