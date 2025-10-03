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

echo "Calculating runner availability SLI across specified organizations..." >&2

# Process organizations
if [ -z "$GITHUB_ORGS" ]; then
    echo "No organizations specified - skipping runner health check" >&2
    cat << EOF
{
    "availability_score": 1.0,
    "total_organizations": 0,
    "total_runners": 0,
    "online_runners": 0,
    "offline_runners": 0,
    "busy_runners": 0
}
EOF
    exit 0
fi

# Initialize aggregated metrics
total_orgs=0
total_runners=0
online_runners=0
offline_runners=0
busy_runners=0

# Process each organization
IFS=',' read -ra ORG_ARRAY <<< "$GITHUB_ORGS"
for org in "${ORG_ARRAY[@]}"; do
    # Trim whitespace
    org=$(echo "$org" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$org" ]; then
        echo "Processing organization: $org" >&2
        total_orgs=$((total_orgs + 1))
        
        # Get runners for this organization
        org_runners_json=$(perform_curl "https://api.github.com/orgs/$org/actions/runners?per_page=100" || echo '{"runners":[]}')
        
        # Check if the response contains runners
        if echo "$org_runners_json" | jq -e '.runners' >/dev/null 2>&1; then
            # Count runners by status
            org_total=$(echo "$org_runners_json" | jq '.runners | length')
            org_online=$(echo "$org_runners_json" | jq '[.runners[] | select(.status == "online")] | length')
            org_offline=$(echo "$org_runners_json" | jq '[.runners[] | select(.status == "offline")] | length')
            org_busy=$(echo "$org_runners_json" | jq '[.runners[] | select(.busy == true)] | length')
            
            # Add to totals
            total_runners=$((total_runners + org_total))
            online_runners=$((online_runners + org_online))
            offline_runners=$((offline_runners + org_offline))
            busy_runners=$((busy_runners + org_busy))
            
            echo "Organization $org: $org_total total runners, $org_online online, $org_offline offline, $org_busy busy" >&2
        else
            echo "No runners found or access denied for organization: $org" >&2
        fi
        
        # Rate limiting protection
        sleep 0.5
    fi
done

# Calculate availability score
if [ $total_runners -eq 0 ]; then
    availability_score="1.0"
else
    # Calculate percentage of online runners
    availability_score=$(echo "scale=4; $online_runners / $total_runners" | bc -l)
    
    # Ensure leading zero for JSON compliance
    if [[ "$availability_score" == .* ]]; then
        availability_score="0$availability_score"
    fi
fi

# Output the results as JSON
cat << EOF
{
    "availability_score": $availability_score,
    "total_organizations": $total_orgs,
    "total_runners": $total_runners,
    "online_runners": $online_runners,
    "offline_runners": $offline_runners,
    "busy_runners": $busy_runners
}
EOF