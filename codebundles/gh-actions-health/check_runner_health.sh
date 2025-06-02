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