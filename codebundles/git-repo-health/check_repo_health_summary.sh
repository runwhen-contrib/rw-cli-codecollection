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

# Function to get basic repository health metrics
function get_repository_health_metrics {
    local repo_name="$1"
    local since_date="$2"
    
    echo "Checking health metrics for repository: $repo_name" >&2
    
    # Get repository basic info
    repo_info=$(perform_curl "https://api.github.com/repos/$repo_name" || echo '{}')
    
    # Get recent commits
    commits_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits?since=$since_date&per_page=100" || echo '[]')
    
    # Get last commit if no recent commits
    if [ "$(echo "$commits_json" | jq 'length')" -eq 0 ]; then
        last_commit_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits?per_page=1" || echo '[]')
    else
        last_commit_json="$commits_json"
    fi
    
    # Extract metrics
    local total_commits=$(echo "$commits_json" | jq 'length')
    local unique_contributors=0
    local days_since_last=999
    
    if [ "$(echo "$last_commit_json" | jq 'length')" -gt 0 ]; then
        unique_contributors=$(echo "$commits_json" | jq -r '[.[].commit.author.email] | unique | length')
        local last_commit_date=$(echo "$last_commit_json" | jq -r '.[0].commit.author.date')
        
        if [ "$last_commit_date" != "null" ]; then
            local last_commit_timestamp=$(date -d "$last_commit_date" +%s)
            local current_timestamp=$(date +%s)
            days_since_last=$(( (current_timestamp - last_commit_timestamp) / 86400 ))
        fi
    fi
    
    # Repository size and other metrics from repo info
    local repo_size=$(echo "$repo_info" | jq -r '.size // 0')
    local stars=$(echo "$repo_info" | jq -r '.stargazers_count // 0')
    local forks=$(echo "$repo_info" | jq -r '.forks_count // 0')
    local open_issues=$(echo "$repo_info" | jq -r '.open_issues_count // 0')
    local default_branch=$(echo "$repo_info" | jq -r '.default_branch // "main"')
    local created_at=$(echo "$repo_info" | jq -r '.created_at // ""')
    local updated_at=$(echo "$repo_info" | jq -r '.updated_at // ""')
    
    # Calculate repository age in days
    local repo_age_days=0
    if [ -n "$created_at" ] && [ "$created_at" != "null" ]; then
        local created_timestamp=$(date -d "$created_at" +%s)
        local current_timestamp=$(date +%s)
        repo_age_days=$(( (current_timestamp - created_timestamp) / 86400 ))
    fi
    
    # Calculate basic health scores
    local min_commits_healthy=${MIN_COMMITS_HEALTHY:-5}
    local commit_frequency_score
    if [ "$total_commits" -ge "$min_commits_healthy" ]; then
        commit_frequency_score="1.0"
    else
        commit_frequency_score=$(echo "scale=3; $total_commits / $min_commits_healthy" | bc -l)
    fi
    
    # Contributor diversity score
    local contributor_diversity_score
    if [ "$unique_contributors" -ge 3 ]; then
        contributor_diversity_score="1.0"
    else
        contributor_diversity_score=$(echo "scale=3; $unique_contributors / 3" | bc -l)
    fi
    
    # Freshness score
    local freshness_score
    if [ "$days_since_last" -le 7 ]; then
        freshness_score="1.0"
    elif [ "$days_since_last" -le 30 ]; then
        freshness_score=$(echo "scale=3; (30 - $days_since_last) / 23" | bc -l)
    else
        freshness_score="0.0"
    fi
    
    # Overall repository health score
    local repo_health_score=$(echo "scale=3; ($commit_frequency_score * 0.4) + ($contributor_diversity_score * 0.3) + ($freshness_score * 0.3)" | bc -l)
    
    # Determine if repository is stale
    local stale_threshold=${STALE_REPO_THRESHOLD_DAYS:-90}
    local is_stale="false"
    if [ "$days_since_last" -gt "$stale_threshold" ]; then
        is_stale="true"
    fi
    
    echo "$repo_name,$total_commits,$unique_contributors,$days_since_last,$repo_health_score,$is_stale,$repo_size,$stars,$forks,$open_issues,$repo_age_days"
}

# Default values
LOOKBACK_DAYS=${COMMIT_LOOKBACK_DAYS:-30}

echo "Checking repository health summary across specified repositories..." >&2

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize counters and arrays
total_repos=0
healthy_repos=0
stale_repos=0
total_commits=0
total_contributors=0
repos_analyzed_list=()
stale_repos_list=()
healthy_repos_list=()
repo_details=()

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        total_repos=$((total_repos + 1))
        repos_analyzed_list+=("$repo_name")
        
        # Get health metrics for this repository
        repo_metrics=$(get_repository_health_metrics "$repo_name" "$date_threshold")
        
        # Parse the metrics
        IFS=',' read -r name commits contributors days_since_last health_score is_stale size stars forks issues age <<< "$repo_metrics"
        
        total_commits=$((total_commits + commits))
        total_contributors=$((total_contributors + contributors))
        
        # Store repository details
        repo_details+=("{\"name\":\"$name\",\"commits\":$commits,\"contributors\":$contributors,\"days_since_last\":$days_since_last,\"health_score\":$health_score,\"is_stale\":$is_stale,\"size\":$size,\"stars\":$stars,\"forks\":$forks,\"open_issues\":$issues,\"age_days\":$age}")
        
        if [ "$is_stale" = "true" ]; then
            stale_repos=$((stale_repos + 1))
            stale_repos_list+=("$repo_name")
        else
            healthy_repos=$((healthy_repos + 1))
            healthy_repos_list+=("$repo_name")
        fi
        
        echo "Repository $repo_name: commits=$commits, contributors=$contributors, health_score=$health_score, stale=$is_stale" >&2
        
        # Rate limiting protection
        sleep 0.2
    fi
done <<< "$repositories"

# Calculate overall health metrics
if [ "$total_repos" -gt 0 ]; then
    overall_health_score=$(echo "scale=3; $healthy_repos / $total_repos" | bc -l)
    avg_commits_per_repo=$(echo "scale=2; $total_commits / $total_repos" | bc -l)
    avg_contributors_per_repo=$(echo "scale=2; $total_contributors / $total_repos" | bc -l)
    stale_percentage=$(echo "scale=2; ($stale_repos * 100) / $total_repos" | bc -l)
else
    overall_health_score=1.0
    avg_commits_per_repo=0
    avg_contributors_per_repo=0
    stale_percentage=0
fi

# Determine if overall health is acceptable
max_stale_percentage=${MAX_STALE_REPOS_PERCENTAGE:-20}
min_health_score=${MIN_REPO_HEALTH_SCORE:-0.7}
health_threshold_met=$(echo "$stale_percentage <= $max_stale_percentage && $overall_health_score >= $min_health_score" | bc -l)

# Convert arrays to JSON format
repos_analyzed_json=$(printf '%s\n' "${repos_analyzed_list[@]}" | jq -R . | jq -s .)
stale_repos_json=$(printf '%s\n' "${stale_repos_list[@]}" | jq -R . | jq -s .)
healthy_repos_json=$(printf '%s\n' "${healthy_repos_list[@]}" | jq -R . | jq -s .)

# Create repository details JSON array
repo_details_json="["
for i in "${!repo_details[@]}"; do
    if [ $i -gt 0 ]; then
        repo_details_json="$repo_details_json,"
    fi
    repo_details_json="$repo_details_json${repo_details[$i]}"
done
repo_details_json="$repo_details_json]"

# Create the final JSON output
cat << EOF
{
    "summary": {
        "repositories_analyzed": $repos_analyzed_json,
        "total_repositories": $total_repos,
        "healthy_repositories": $healthy_repos_json,
        "stale_repositories": $stale_repos_json,
        "healthy_count": $healthy_repos,
        "stale_count": $stale_repos,
        "overall_health_score": $overall_health_score,
        "stale_percentage": $stale_percentage,
        "health_threshold_met": $([ "$health_threshold_met" -eq 1 ] && echo "true" || echo "false"),
        "lookback_days": $LOOKBACK_DAYS,
        "date_threshold": "$date_threshold"
    },
    "metrics": {
        "total_commits": $total_commits,
        "total_contributors": $total_contributors,
        "avg_commits_per_repo": $avg_commits_per_repo,
        "avg_contributors_per_repo": $avg_contributors_per_repo,
        "stale_threshold_days": ${STALE_REPO_THRESHOLD_DAYS:-90},
        "min_commits_healthy": ${MIN_COMMITS_HEALTHY:-5},
        "max_stale_percentage": $max_stale_percentage,
        "min_health_score": $min_health_score
    },
    "repository_details": $repo_details_json
}
EOF
