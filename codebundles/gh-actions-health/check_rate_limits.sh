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

# Function to perform curl requests with error handling
function perform_curl {
    local url="$1"
    local response
    response=$(curl -sS -I "${HEADERS[@]}" "$url") || error_exit "Failed to perform curl request to $url"
    echo "$response"
}

echo "Checking GitHub API rate limits..." >&2

# Get rate limit information
rate_limit_json=$(curl -sS "${HEADERS[@]}" "https://api.github.com/rate_limit") || error_exit "Failed to fetch rate limit information"

# Extract core rate limit information
core_limit=$(echo "$rate_limit_json" | jq '.rate.limit')
core_remaining=$(echo "$rate_limit_json" | jq '.rate.remaining')
core_reset=$(echo "$rate_limit_json" | jq '.rate.reset')
core_used=$(echo "$rate_limit_json" | jq '.rate.used // 0')

# Calculate usage percentage
if [ "$core_limit" -gt 0 ]; then
    usage_percentage=$(echo "scale=2; ($core_used / $core_limit) * 100" | bc -l)
else
    usage_percentage=0
fi

# Convert reset time to human readable
reset_time=$(date -d @"$core_reset" -u +%Y-%m-%dT%H:%M:%SZ)
current_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Calculate minutes until reset
minutes_until_reset=$(echo "scale=0; ($core_reset - $(date +%s)) / 60" | bc -l)

# Get search rate limits if available
search_limit=0
search_remaining=0
search_used=0
search_reset=0

if echo "$rate_limit_json" | jq -e '.search' >/dev/null; then
    search_limit=$(echo "$rate_limit_json" | jq '.search.limit')
    search_remaining=$(echo "$rate_limit_json" | jq '.search.remaining')
    search_reset=$(echo "$rate_limit_json" | jq '.search.reset')
    search_used=$(echo "$rate_limit_json" | jq '.search.used // 0')
fi

# Get GraphQL rate limits if available
graphql_limit=0
graphql_remaining=0
graphql_used=0
graphql_reset=0

if echo "$rate_limit_json" | jq -e '.graphql' >/dev/null; then
    graphql_limit=$(echo "$rate_limit_json" | jq '.graphql.limit')
    graphql_remaining=$(echo "$rate_limit_json" | jq '.graphql.remaining')
    graphql_reset=$(echo "$rate_limit_json" | jq '.graphql.reset')
    graphql_used=$(echo "$rate_limit_json" | jq '.graphql.used // 0')
fi

# Determine status
status="healthy"
if [ "$usage_percentage" != "0" ] && echo "$usage_percentage > 70" | bc -l | grep -q 1; then
    status="warning"
fi
if [ "$usage_percentage" != "0" ] && echo "$usage_percentage > 90" | bc -l | grep -q 1; then
    status="critical"
fi

# Create the final JSON output
cat << EOF
{
    "core": {
        "limit": $core_limit,
        "remaining": $core_remaining,
        "used": $core_used,
        "reset": $core_reset,
        "reset_time": "$reset_time",
        "usage_percentage": $usage_percentage
    },
    "search": {
        "limit": $search_limit,
        "remaining": $search_remaining,
        "used": $search_used,
        "reset": $search_reset
    },
    "graphql": {
        "limit": $graphql_limit,
        "remaining": $graphql_remaining,
        "used": $graphql_used,
        "reset": $graphql_reset
    },
    "status": "$status",
    "minutes_until_reset": $minutes_until_reset,
    "current_time": "$current_time",
    "warning_threshold": 70,
    "critical_threshold": 90
}
EOF 