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

# Function to analyze commit message quality
function analyze_commit_message_quality {
    local messages="$1"
    local total_commits="$2"
    
    if [ "$total_commits" -eq 0 ]; then
        echo "1.0"
        return
    fi
    
    # Count commits with good practices
    local good_messages=0
    
    while IFS= read -r message; do
        if [ -n "$message" ]; then
            # Check for good commit message practices
            local message_length=${#message}
            local has_type=false
            local has_description=false
            
            # Check for conventional commit format or descriptive messages
            if [[ "$message" =~ ^(feat|fix|docs|style|refactor|test|chore|ci|build|perf)(\(.+\))?:\ .+ ]] || 
               [[ "$message" =~ ^(Add|Fix|Update|Remove|Improve|Implement|Create|Delete|Refactor)\ .+ ]]; then
                has_type=true
            fi
            
            # Check for adequate description length
            if [ "$message_length" -ge 10 ] && [ "$message_length" -le 72 ]; then
                has_description=true
            fi
            
            # Count as good if it has type or good description
            if [ "$has_type" = true ] || [ "$has_description" = true ]; then
                good_messages=$((good_messages + 1))
            fi
        fi
    done <<< "$messages"
    
    # Calculate quality score
    local quality_score=$(echo "scale=3; $good_messages / $total_commits" | bc -l)
    echo "$quality_score"
}

# Function to get detailed commit analysis for a repository
function analyze_repository_commits {
    local repo_name="$1"
    local since_date="$2"
    
    echo "Analyzing commits for repository: $repo_name" >&2
    
    # Get commits since the specified date
    commits_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits?since=$since_date&per_page=100" || echo '[]')
    
    # Check if we got valid JSON
    if ! echo "$commits_json" | jq -e '.' >/dev/null 2>&1; then
        echo "Invalid JSON response for $repo_name, skipping..." >&2
        echo '{
            "repository": "'$repo_name'",
            "total_commits": 0,
            "unique_contributors": 0,
            "days_since_last_commit": 999,
            "commit_frequency_score": 0,
            "contributor_diversity_score": 0,
            "message_quality_score": 0,
            "repository_health_score": 0,
            "is_stale": true,
            "recent_commits": []
        }'
        return
    fi
    
    # Extract commit data
    local total_commits=$(echo "$commits_json" | jq 'length')
    
    if [ "$total_commits" -eq 0 ]; then
        # No recent commits, check last commit date
        last_commit_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits?per_page=1" || echo '[]')
        local days_since_last=999
        
        if [ "$(echo "$last_commit_json" | jq 'length')" -gt 0 ]; then
            local last_commit_date=$(echo "$last_commit_json" | jq -r '.[0].commit.author.date')
            if [ "$last_commit_date" != "null" ]; then
                local last_commit_timestamp=$(date -d "$last_commit_date" +%s)
                local current_timestamp=$(date +%s)
                days_since_last=$(( (current_timestamp - last_commit_timestamp) / 86400 ))
            fi
        fi
        
        echo '{
            "repository": "'$repo_name'",
            "total_commits": 0,
            "unique_contributors": 0,
            "days_since_last_commit": '$days_since_last',
            "commit_frequency_score": 0,
            "contributor_diversity_score": 0,
            "message_quality_score": 0,
            "repository_health_score": 0,
            "is_stale": true,
            "recent_commits": []
        }'
        return
    fi
    
    # Get unique contributors
    local contributors=$(echo "$commits_json" | jq -r '[.[].commit.author.email] | unique | length')
    
    # Get days since last commit
    local last_commit_date=$(echo "$commits_json" | jq -r '.[0].commit.author.date')
    local last_commit_timestamp=$(date -d "$last_commit_date" +%s)
    local current_timestamp=$(date +%s)
    local days_since_last=$(( (current_timestamp - last_commit_timestamp) / 86400 ))
    
    # Extract commit messages for quality analysis
    local commit_messages=$(echo "$commits_json" | jq -r '.[].commit.message | split("\n")[0]')
    
    # Calculate scores
    local commit_frequency_score
    local min_commits_healthy=${MIN_COMMITS_HEALTHY:-5}
    if [ "$total_commits" -ge "$min_commits_healthy" ]; then
        commit_frequency_score="1.0"
    else
        commit_frequency_score=$(echo "scale=3; $total_commits / $min_commits_healthy" | bc -l)
    fi
    
    # Contributor diversity score (more contributors = better, max score at 5+ contributors)
    local contributor_diversity_score
    if [ "$contributors" -ge 5 ]; then
        contributor_diversity_score="1.0"
    else
        contributor_diversity_score=$(echo "scale=3; $contributors / 5" | bc -l)
    fi
    
    # Message quality score
    local message_quality_score=$(analyze_commit_message_quality "$commit_messages" "$total_commits")
    
    # Repository freshness score (based on days since last commit)
    local freshness_score
    if [ "$days_since_last" -le 7 ]; then
        freshness_score="1.0"
    elif [ "$days_since_last" -le 30 ]; then
        freshness_score=$(echo "scale=3; (30 - $days_since_last) / 23" | bc -l)
    else
        freshness_score="0.0"
    fi
    
    # Calculate overall repository health score (weighted average)
    local repo_health_score=$(echo "scale=3; ($commit_frequency_score * 0.4) + ($contributor_diversity_score * 0.25) + ($freshness_score * 0.2) + ($message_quality_score * 0.15)" | bc -l)
    
    # Determine if repository is stale
    local stale_threshold=${STALE_REPO_THRESHOLD_DAYS:-90}
    local is_stale="false"
    if [ "$days_since_last" -gt "$stale_threshold" ]; then
        is_stale="true"
    fi
    
    # Get recent commits summary (last 10)
    local recent_commits=$(echo "$commits_json" | jq '[.[0:10] | .[] | {
        sha: .sha[0:7],
        message: .commit.message | split("\n")[0],
        author: .commit.author.name,
        date: .commit.author.date,
        url: .html_url
    }]')
    
    # Create the result JSON
    cat << EOF
{
    "repository": "$repo_name",
    "total_commits": $total_commits,
    "unique_contributors": $contributors,
    "days_since_last_commit": $days_since_last,
    "commit_frequency_score": $commit_frequency_score,
    "contributor_diversity_score": $contributor_diversity_score,
    "message_quality_score": $message_quality_score,
    "freshness_score": $freshness_score,
    "repository_health_score": $repo_health_score,
    "is_stale": $is_stale,
    "recent_commits": $recent_commits
}
EOF
}

# Default values
LOOKBACK_DAYS=${COMMIT_LOOKBACK_DAYS:-30}

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

echo "Analyzing recent commits across specified repositories since $date_threshold..." >&2

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize results array
all_results="[]"

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        # Analyze this repository
        repo_analysis=$(analyze_repository_commits "$repo_name" "$date_threshold")
        
        # Add to results array
        all_results=$(echo "$all_results [$repo_analysis]" | jq -s 'add')
        
        # Rate limiting protection
        sleep 0.3
    fi
done <<< "$repositories"

# Output the results
echo "$all_results"
