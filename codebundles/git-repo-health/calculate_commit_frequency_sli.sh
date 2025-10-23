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

# Function to calculate commit frequency score for a repository
function calculate_commit_frequency_score {
    local repo_name="$1"
    local since_date="$2"
    
    echo "Calculating commit frequency for repository: $repo_name" >&2
    
    # Get recent commits
    commits_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits?since=$since_date&per_page=100" || echo '[]')
    
    # Count total commits
    local total_commits=$(echo "$commits_json" | jq 'length')
    
    # Calculate commit frequency score
    local min_commits_healthy=${MIN_COMMITS_HEALTHY:-5}
    local commit_frequency_score
    
    if [ "$total_commits" -ge "$min_commits_healthy" ]; then
        commit_frequency_score="1.0"
    else
        commit_frequency_score=$(echo "scale=3; $total_commits / $min_commits_healthy" | bc -l)
    fi
    
    # Ensure score is between 0 and 1
    commit_frequency_score=$(echo "$commit_frequency_score" | awk '{if($1>1) print 1; else if($1<0) print 0; else print $1}')
    
    echo "$total_commits,$commit_frequency_score"
}

# Default values
LOOKBACK_DAYS=${SLI_LOOKBACK_DAYS:-1}

echo "Calculating commit frequency SLI across specified repositories..." >&2

# Calculate the date threshold
date_threshold=$(date -d "$LOOKBACK_DAYS days ago" -u +%Y-%m-%dT%H:%M:%SZ)

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize counters
total_repos=0
total_commits=0
repos_meeting_threshold=0
total_frequency_score=0
repos_analyzed=()
repo_commit_counts=()
repo_frequency_scores=()

# Thresholds
min_commit_frequency_score=${MIN_COMMIT_FREQUENCY_SCORE:-0.6}

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        total_repos=$((total_repos + 1))
        repos_analyzed+=("$repo_name")
        
        # Calculate commit frequency score for this repository
        result=$(calculate_commit_frequency_score "$repo_name" "$date_threshold")
        IFS=',' read -r repo_commits repo_score <<< "$result"
        
        # Add to totals
        total_commits=$((total_commits + repo_commits))
        total_frequency_score=$(echo "$total_frequency_score + $repo_score" | bc -l)
        repo_commit_counts+=("$repo_commits")
        repo_frequency_scores+=("$repo_score")
        
        # Check if repository meets frequency threshold
        meets_threshold=$(echo "$repo_score >= $min_commit_frequency_score" | bc -l)
        if [ "$meets_threshold" -eq 1 ]; then
            repos_meeting_threshold=$((repos_meeting_threshold + 1))
        fi
        
        echo "Repository $repo_name: $repo_commits commits, frequency score: $repo_score" >&2
        
        # Rate limiting protection
        sleep 0.2
    fi
done <<< "$repositories"

# Calculate overall metrics
if [ "$total_repos" -gt 0 ]; then
    avg_commits_per_repo=$(echo "scale=2; $total_commits / $total_repos" | bc -l)
    avg_frequency_score=$(echo "scale=3; $total_frequency_score / $total_repos" | bc -l)
    repos_meeting_threshold_percentage=$(echo "scale=3; $repos_meeting_threshold / $total_repos" | bc -l)
else
    avg_commits_per_repo=0
    avg_frequency_score=1.0
    repos_meeting_threshold_percentage=1.0
fi

# Determine SLI score (1 if enough repos meet threshold, 0 otherwise)
# We consider the SLI healthy if at least 70% of repos meet the commit frequency threshold
min_repos_threshold_percentage=${MIN_COMMIT_FREQUENCY_SCORE:-0.6}
sli_score=$(echo "$repos_meeting_threshold_percentage >= $min_repos_threshold_percentage" | bc -l)

# Convert arrays to JSON
repos_json=$(printf '%s\n' "${repos_analyzed[@]}" | jq -R . | jq -s .)
commit_counts_json=$(printf '%s\n' "${repo_commit_counts[@]}" | jq -R 'tonumber' | jq -s .)
frequency_scores_json=$(printf '%s\n' "${repo_frequency_scores[@]}" | jq -R 'tonumber' | jq -s .)

# Create the final JSON output
cat << EOF
{
    "sli_score": $sli_score,
    "metrics": {
        "total_repositories": $total_repos,
        "total_commits": $total_commits,
        "repos_meeting_threshold": $repos_meeting_threshold,
        "avg_commits_per_repo": $avg_commits_per_repo,
        "avg_frequency_score": $avg_frequency_score,
        "repos_meeting_threshold_percentage": $repos_meeting_threshold_percentage,
        "lookback_days": $LOOKBACK_DAYS
    },
    "repositories": $repos_json,
    "commit_counts": $commit_counts_json,
    "frequency_scores": $frequency_scores_json,
    "thresholds": {
        "min_commits_healthy": ${MIN_COMMITS_HEALTHY:-5},
        "min_commit_frequency_score": $min_commit_frequency_score,
        "min_repos_threshold_percentage": $min_repos_threshold_percentage
    },
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
