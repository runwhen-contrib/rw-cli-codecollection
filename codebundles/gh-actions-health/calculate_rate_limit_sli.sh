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

# Build the headers array for curl
HEADERS=()
if [ -n "$GITHUB_TOKEN" ]; then
    HEADERS+=(-H "Authorization: token $GITHUB_TOKEN")
fi
HEADERS+=(-H "Accept: application/vnd.github.v3+json")

echo "Calculating GitHub API rate limit SLI..." >&2

# Get rate limit information
rate_limit_json=$(curl -sS "${HEADERS[@]}" "https://api.github.com/rate_limit") || error_exit "Failed to fetch rate limit information"

# Extract core rate limit information
core_limit=$(echo "$rate_limit_json" | jq '.rate.limit')
core_remaining=$(echo "$rate_limit_json" | jq '.rate.remaining')
core_used=$(echo "$rate_limit_json" | jq '.rate.used // 0')

# Calculate usage percentage
if [ "$core_limit" -gt 0 ]; then
    usage_percentage=$(echo "scale=2; ($core_used / $core_limit) * 100" | bc -l)
    
    # Ensure leading zero for JSON compliance
    if [[ "$usage_percentage" == .* ]]; then
        usage_percentage="0$usage_percentage"
    fi
else
    usage_percentage="0"
fi

# Create the final JSON output
cat << EOF
{
    "limit": $core_limit,
    "remaining": $core_remaining,
    "used": $core_used,
    "usage_percentage": $usage_percentage
}
EOF