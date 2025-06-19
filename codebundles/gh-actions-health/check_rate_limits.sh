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

# Extract core rate limit information (with null handling)
core_limit=$(echo "$rate_limit_json" | jq '.rate.limit // 0')
core_remaining=$(echo "$rate_limit_json" | jq '.rate.remaining // 0')
core_reset=$(echo "$rate_limit_json" | jq '.rate.reset // 0')
core_used=$(echo "$rate_limit_json" | jq '.rate.used // 0')

# Validate extracted values are numbers
if ! echo "$core_limit" | grep -E '^[0-9]+$' >/dev/null; then core_limit=0; fi
if ! echo "$core_remaining" | grep -E '^[0-9]+$' >/dev/null; then core_remaining=0; fi
if ! echo "$core_reset" | grep -E '^[0-9]+$' >/dev/null; then core_reset=0; fi
if ! echo "$core_used" | grep -E '^[0-9]+$' >/dev/null; then core_used=0; fi

# Calculate usage percentage (ensure valid number format)
if [ "$core_limit" -gt 0 ]; then
    usage_percentage=$(echo "scale=2; ($core_used / $core_limit) * 100" | bc -l | sed 's/^\./0./')
    # Ensure it's a valid number, default to 0 if calculation fails
    if ! echo "$usage_percentage" | grep -E '^[0-9]+\.?[0-9]*$' >/dev/null; then
        usage_percentage="0.00"
    fi
else
    usage_percentage="0.00"
fi

# Convert reset time to human readable (with error handling)
if [ "$core_reset" != "null" ] && [ "$core_reset" -gt 0 ]; then
    reset_time=$(date -d @"$core_reset" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
else
    reset_time="unknown"
fi
current_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Calculate minutes until reset (ensure non-negative)
if [ "$core_reset" != "null" ] && [ "$core_reset" -gt 0 ]; then
    minutes_calc=$(echo "scale=0; ($core_reset - $(date +%s)) / 60" | bc -l 2>/dev/null || echo "0")
    # Ensure minutes is non-negative
    if [ "$minutes_calc" -lt 0 ]; then
        minutes_until_reset=0
    else
        minutes_until_reset="$minutes_calc"
    fi
else
    minutes_until_reset=0
fi

# Get search rate limits if available (with null handling)
search_limit=0
search_remaining=0
search_used=0
search_reset=0

if echo "$rate_limit_json" | jq -e '.search' >/dev/null; then
    search_limit=$(echo "$rate_limit_json" | jq '.search.limit // 0')
    search_remaining=$(echo "$rate_limit_json" | jq '.search.remaining // 0')
    search_reset=$(echo "$rate_limit_json" | jq '.search.reset // 0')
    search_used=$(echo "$rate_limit_json" | jq '.search.used // 0')
    
    # Validate values are numbers
    if ! echo "$search_limit" | grep -E '^[0-9]+$' >/dev/null; then search_limit=0; fi
    if ! echo "$search_remaining" | grep -E '^[0-9]+$' >/dev/null; then search_remaining=0; fi
    if ! echo "$search_reset" | grep -E '^[0-9]+$' >/dev/null; then search_reset=0; fi
    if ! echo "$search_used" | grep -E '^[0-9]+$' >/dev/null; then search_used=0; fi
fi

# Get GraphQL rate limits if available (with null handling)
graphql_limit=0
graphql_remaining=0
graphql_used=0
graphql_reset=0

if echo "$rate_limit_json" | jq -e '.graphql' >/dev/null; then
    graphql_limit=$(echo "$rate_limit_json" | jq '.graphql.limit // 0')
    graphql_remaining=$(echo "$rate_limit_json" | jq '.graphql.remaining // 0')
    graphql_reset=$(echo "$rate_limit_json" | jq '.graphql.reset // 0')
    graphql_used=$(echo "$rate_limit_json" | jq '.graphql.used // 0')
    
    # Validate values are numbers
    if ! echo "$graphql_limit" | grep -E '^[0-9]+$' >/dev/null; then graphql_limit=0; fi
    if ! echo "$graphql_remaining" | grep -E '^[0-9]+$' >/dev/null; then graphql_remaining=0; fi
    if ! echo "$graphql_reset" | grep -E '^[0-9]+$' >/dev/null; then graphql_reset=0; fi
    if ! echo "$graphql_used" | grep -E '^[0-9]+$' >/dev/null; then graphql_used=0; fi
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