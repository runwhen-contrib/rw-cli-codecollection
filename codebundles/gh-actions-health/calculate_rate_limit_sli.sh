#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e
source "$(dirname "$0")/_github_auth.sh"

# Function to handle error messages and exit

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