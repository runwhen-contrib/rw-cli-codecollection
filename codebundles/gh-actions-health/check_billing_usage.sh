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

echo "Checking GitHub Actions billing and usage for organizations: $GITHUB_ORGS..." >&2

# Initialize aggregated results
total_usage_minutes=0
total_included_minutes=0
organizations_analyzed=()
org_details="[]"

# Process each organization
IFS=',' read -ra ORG_ARRAY <<< "$GITHUB_ORGS"
for org in "${ORG_ARRAY[@]}"; do
    # Trim whitespace
    org=$(echo "$org" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -n "$org" ]; then
        echo "Checking billing for organization: $org" >&2
        organizations_analyzed+=("$org")
        
        # Get billing information for this organization
        billing_json=$(perform_curl "https://api.github.com/orgs/$org/settings/billing/actions" || echo '{"total_minutes_used":0,"included_minutes":0}')
        
        # Extract billing data for this organization
        if echo "$billing_json" | jq -e '.total_minutes_used' >/dev/null 2>&1; then
            org_usage=$(echo "$billing_json" | jq '.total_minutes_used // 0')
            org_included=$(echo "$billing_json" | jq '.included_minutes // 0')
            
            # Calculate percentages for this organization
            org_usage_percentage=0
            if [ "$org_included" -gt 0 ]; then
                org_usage_percentage=$(echo "scale=2; $org_usage / $org_included * 100" | bc -l)
            fi
            
            # Add to totals
            total_usage_minutes=$((total_usage_minutes + org_usage))
            total_included_minutes=$((total_included_minutes + org_included))
            
            # Create organization detail entry
            org_detail=$(cat << EOF
{
    "organization": "$org",
    "usage_minutes": $org_usage,
    "included_minutes": $org_included,
    "usage_percentage": $org_usage_percentage,
    "overage_minutes": $([ "$org_usage" -gt "$org_included" ] && echo $((org_usage - org_included)) || echo "0")
}
EOF
)
            
            # Add to org_details array
            org_details=$(echo "$org_details" | jq --argjson detail "$org_detail" '. + [$detail]')
            
            echo "Organization $org: $org_usage/$org_included minutes (${org_usage_percentage}%)" >&2
        else
            echo "Failed to fetch billing data or access denied for organization: $org" >&2
            
            # Add placeholder entry
            org_detail=$(cat << EOF
{
    "organization": "$org",
    "usage_minutes": 0,
    "included_minutes": 0,
    "usage_percentage": 0,
    "overage_minutes": 0,
    "error": "Access denied or billing data unavailable"
}
EOF
)
            org_details=$(echo "$org_details" | jq --argjson detail "$org_detail" '. + [$detail]')
        fi
        
        # Rate limiting protection
        sleep 0.5
    fi
done

# Calculate overall metrics
overall_usage_percentage=0
total_overage_minutes=0
if [ "$total_included_minutes" -gt 0 ]; then
    overall_usage_percentage=$(echo "scale=2; $total_usage_minutes / $total_included_minutes * 100" | bc -l)
fi

if [ "$total_usage_minutes" -gt "$total_included_minutes" ]; then
    total_overage_minutes=$((total_usage_minutes - total_included_minutes))
fi

# Convert organizations array to JSON
orgs_analyzed_json=$(printf '%s\n' "${organizations_analyzed[@]}" | jq -R . | jq -s .)

# Create the final JSON output
cat << EOF
{
    "organizations_analyzed": $orgs_analyzed_json,
    "total_usage_minutes": $total_usage_minutes,
    "total_included_minutes": $total_included_minutes,
    "overall_usage_percentage": $overall_usage_percentage,
    "total_overage_minutes": $total_overage_minutes,
    "organization_details": $org_details,
    "recommendations": [
        $(if [ "$total_overage_minutes" -gt 0 ]; then echo "\"Review workflows contributing to overage minutes\""; fi),
        $(if (( $(echo "$overall_usage_percentage > 80" | bc -l) )); then echo "\"Consider optimizing workflow efficiency\""; fi),
        $(if [ "${#organizations_analyzed[@]}" -gt 1 ]; then echo "\"Review usage distribution across organizations\""; fi)
    ]
}
EOF 