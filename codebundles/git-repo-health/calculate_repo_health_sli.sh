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

# Function to calculate repository health score
function calculate_repository_health_score {
    local repo_name="$1"
    local since_date="$2"
    
    echo "Calculating health score for repository: $repo_name" >&2
    
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
    
    # Extract basic metrics
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
    
    # Calculate individual scores
    
    # 1. Commit Frequency Score (40% weight)
    local min_commits_healthy=${MIN_COMMITS_HEALTHY:-5}
    local commit_frequency_score
    if [ "$total_commits" -ge "$min_commits_healthy" ]; then
        commit_frequency_score="1.0"
    else
        commit_frequency_score=$(echo "scale=3; $total_commits / $min_commits_healthy" | bc -l)
    fi
    
    # 2. Contributor Diversity Score (25% weight)
    local contributor_diversity_score
    if [ "$unique_contributors" -ge 3 ]; then
        contributor_diversity_score="1.0"
    elif [ "$unique_contributors" -eq 0 ]; then
        contributor_diversity_score="0.0"
    else
        contributor_diversity_score=$(echo "scale=3; $unique_contributors / 3" | bc -l)
    fi
    
    # 3. Repository Freshness Score (20% weight)
    local freshness_score
    if [ "$days_since_last" -le 7 ]; then
        freshness_score="1.0"
    elif [ "$days_since_last" -le 30 ]; then
        freshness_score=$(echo "scale=3; (30 - $days_since_last) / 23" | bc -l)
    elif [ "$days_since_last" -le 90 ]; then
        freshness_score=$(echo "scale=3; (90 - $days_since_last) / 60 * 0.3" | bc -l)
    else
        freshness_score="0.0"
    fi
    
    # 4. Repository Activity Score (15% weight) - based on repository metadata
    local activity_score="0.5"  # Default neutral score
    if echo "$repo_info" | jq -e '.' >/dev/null 2>&1; then
        local stars=$(echo "$repo_info" | jq -r '.stargazers_count // 0')
        local forks=$(echo "$repo_info" | jq -r '.forks_count // 0')
        local open_issues=$(echo "$repo_info" | jq -r '.open_issues_count // 0')
        local is_archived=$(echo "$repo_info" | jq -r '.archived // false')
        
        if [ "$is_archived" = "true" ]; then
            activity_score="0.0"
        elif [ "$stars" -gt 100 ] || [ "$forks" -gt 20 ]; then
            activity_score="1.0"
        elif [ "$stars" -gt 10 ] || [ "$forks" -gt 5 ]; then
            activity_score="0.8"
        elif [ "$open_issues" -gt 0 ]; then
            activity_score="0.6"
        fi
    fi
    
    # Calculate weighted overall health score
    local repo_health_score=$(echo "scale=3; ($commit_frequency_score * 0.4) + ($contributor_diversity_score * 0.25) + ($freshness_score * 0.2) + ($activity_score * 0.15)" | bc -l)
    
    # Ensure score is between 0 and 1
    repo_health_score=$(echo "$repo_health_score" | awk '{if($1>1) print 1; else if($1<0) print 0; else print $1}')
    
    echo "$repo_health_score"
}

# Default values
LOOKBACK_DAYS=${SLI_LOOKBACK_DAYS:-1}

echo "Calculating repository health SLI across specified repositories..." >&2

# Calculate the date threshold (for SLI, we use a shorter lookback period)
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize counters
total_repos=0
total_health_score=0
healthy_repos=0
repos_analyzed=()
individual_scores=()

# Thresholds
min_repo_health_score=${MIN_REPO_HEALTH_SCORE:-0.7}

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        total_repos=$((total_repos + 1))
        repos_analyzed+=("$repo_name")
        
        # Calculate health score for this repository
        repo_score=$(calculate_repository_health_score "$repo_name" "$date_threshold")
        
        # Add to totals
        total_health_score=$(echo "$total_health_score + $repo_score" | bc -l)
        individual_scores+=("$repo_score")
        
        # Check if repository meets health threshold
        is_healthy=$(echo "$repo_score >= $min_repo_health_score" | bc -l)
        if [ "$is_healthy" -eq 1 ]; then
            healthy_repos=$((healthy_repos + 1))
        fi
        
        echo "Repository $repo_name health score: $repo_score" >&2
        
        # Rate limiting protection
        sleep 0.2
    fi
done <<< "$repositories"

# Calculate overall metrics
if [ "$total_repos" -gt 0 ]; then
    avg_health_score=$(echo "scale=3; $total_health_score / $total_repos" | bc -l)
    healthy_percentage=$(echo "scale=3; $healthy_repos / $total_repos" | bc -l)
else
    avg_health_score=1.0
    healthy_percentage=1.0
fi

# Determine SLI score (1 if healthy percentage meets threshold, 0 otherwise)
min_healthy_percentage=${MIN_REPO_HEALTH_SCORE:-0.7}
sli_score=$(echo "$healthy_percentage >= $min_healthy_percentage" | bc -l)

# Convert arrays to JSON
repos_json=$(printf '%s\n' "${repos_analyzed[@]}" | jq -R . | jq -s .)
scores_json=$(printf '%s\n' "${individual_scores[@]}" | jq -R 'tonumber' | jq -s .)

# Create the final JSON output
cat << EOF
{
    "sli_score": $sli_score,
    "metrics": {
        "total_repositories": $total_repos,
        "healthy_repositories": $healthy_repos,
        "avg_health_score": $avg_health_score,
        "healthy_percentage": $healthy_percentage,
        "min_health_threshold": $min_healthy_percentage,
        "lookback_days": $LOOKBACK_DAYS
    },
    "repositories": $repos_json,
    "individual_scores": $scores_json,
    "thresholds": {
        "min_repo_health_score": $min_repo_health_score,
        "min_commits_healthy": ${MIN_COMMITS_HEALTHY:-5}
    },
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
