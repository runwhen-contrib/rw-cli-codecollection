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

if [ -z "$GITHUB_ORGS" ]; then
    error_exit "GITHUB_ORGS is required"
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

echo "Checking GitHub Actions runner health for organizations: $GITHUB_ORGS..." >&2

# Initialize aggregated results
all_offline_runners="[]"
all_busy_runners="[]"
all_idle_runners="[]"
total_runners=0
organizations_analyzed=()

# Process each organization
IFS=',' read -ra ORG_ARRAY <<< "$GITHUB_ORGS"
for org in "${ORG_ARRAY[@]}"; do
    # Trim whitespace
    org=$(echo "$org" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$org" ]; then
        echo "Checking runners for organization: $org" >&2
        organizations_analyzed+=("$org")
        
        # Get self-hosted runners for this organization
        runners_json=$(perform_curl "https://api.github.com/orgs/$org/actions/runners?per_page=100" || echo '{"runners":[]}')
        
        # Check if the response contains runners
        if echo "$runners_json" | jq -e '.runners' >/dev/null 2>&1; then
            # Extract offline runners for this organization
            org_offline_runners=$(echo "$runners_json" | jq -r --arg org "$org" '[
                .runners[] |
                select(.status == "offline") |
                {
                    organization: $org,
                    name: .name,
                    status: .status,
                    os: .os,
                    labels: [.labels[].name],
                    busy: .busy
                }
            ]')
            
            # Extract busy runners for this organization
            org_busy_runners=$(echo "$runners_json" | jq -r --arg org "$org" '[
                .runners[] |
                select(.busy == true and .status == "online") |
                {
                    organization: $org,
                    name: .name,
                    status: .status,
                    os: .os,
                    labels: [.labels[].name],
                    busy: .busy
                }
            ]')
            
            # Extract idle runners for this organization
            org_idle_runners=$(echo "$runners_json" | jq -r --arg org "$org" '[
                .runners[] |
                select(.busy == false and .status == "online") |
                {
                    organization: $org,
                    name: .name,
                    status: .status,
                    os: .os,
                    labels: [.labels[].name],
                    busy: .busy
                }
            ]')
            
            # Get runner count for this organization
            org_runner_count=$(echo "$runners_json" | jq '.runners | length')
            total_runners=$((total_runners + org_runner_count))
            
            # Merge with aggregated results
            all_offline_runners=$(echo "$all_offline_runners $org_offline_runners" | jq -s 'add')
            all_busy_runners=$(echo "$all_busy_runners $org_busy_runners" | jq -s 'add')
            all_idle_runners=$(echo "$all_idle_runners $org_idle_runners" | jq -s 'add')
            
            echo "Organization $org: $org_runner_count total runners" >&2
        else
            echo "No runners found or access denied for organization: $org" >&2
        fi
        
        # Rate limiting protection
        sleep 0.5
    fi
done

# Calculate utilization metrics
offline_count=$(echo "$all_offline_runners" | jq 'length')
busy_count=$(echo "$all_busy_runners" | jq 'length')
idle_count=$(echo "$all_idle_runners" | jq 'length')

# Convert organizations array to JSON
orgs_analyzed_json=$(printf '%s\n' "${organizations_analyzed[@]}" | jq -R . | jq -s .)

# Create the final JSON output
cat << EOF
{
    "organizations_analyzed": $orgs_analyzed_json,
    "total_runners": $total_runners,
    "offline_runners": $all_offline_runners,
    "offline_runners_count": $offline_count,
    "busy_runners": $all_busy_runners,
    "busy_runners_count": $busy_count,
    "idle_runners": $all_idle_runners,
    "idle_runners_count": $idle_count,
    "utilization_percentage": $(if [ "$total_runners" -gt 0 ]; then echo "scale=2; $busy_count / $total_runners * 100" | bc -l; else echo "0"; fi)
}
EOF 