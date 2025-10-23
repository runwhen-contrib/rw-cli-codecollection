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

# Function to check if repository is stale and get details
function check_repository_staleness {
    local repo_name="$1"
    
    echo "Checking staleness for repository: $repo_name" >&2
    
    # Get repository basic info
    repo_info=$(perform_curl "https://api.github.com/repos/$repo_name" || echo '{}')
    
    # Get last commit
    last_commit_json=$(perform_curl "https://api.github.com/repos/$repo_name/commits?per_page=1" || echo '[]')
    
    # Extract repository information
    local repo_description=$(echo "$repo_info" | jq -r '.description // ""')
    local repo_language=$(echo "$repo_info" | jq -r '.language // ""')
    local repo_size=$(echo "$repo_info" | jq -r '.size // 0')
    local stars=$(echo "$repo_info" | jq -r '.stargazers_count // 0')
    local forks=$(echo "$repo_info" | jq -r '.forks_count // 0')
    local open_issues=$(echo "$repo_info" | jq -r '.open_issues_count // 0')
    local created_at=$(echo "$repo_info" | jq -r '.created_at // ""')
    local updated_at=$(echo "$repo_info" | jq -r '.updated_at // ""')
    local default_branch=$(echo "$repo_info" | jq -r '.default_branch // "main"')
    local is_archived=$(echo "$repo_info" | jq -r '.archived // false')
    local is_disabled=$(echo "$repo_info" | jq -r '.disabled // false')
    local visibility=$(echo "$repo_info" | jq -r '.visibility // "public"')
    
    # Get last commit information
    local days_since_last_commit=999
    local last_commit_sha=""
    local last_commit_message=""
    local last_commit_author=""
    local last_commit_date=""
    
    if [ "$(echo "$last_commit_json" | jq 'length')" -gt 0 ]; then
        last_commit_date=$(echo "$last_commit_json" | jq -r '.[0].commit.author.date')
        last_commit_sha=$(echo "$last_commit_json" | jq -r '.[0].sha[0:7]')
        last_commit_message=$(echo "$last_commit_json" | jq -r '.[0].commit.message | split("\n")[0]')
        last_commit_author=$(echo "$last_commit_json" | jq -r '.[0].commit.author.name')
        
        if [ "$last_commit_date" != "null" ]; then
            local last_commit_timestamp=$(date -d "$last_commit_date" +%s)
            local current_timestamp=$(date +%s)
            days_since_last_commit=$(( (current_timestamp - last_commit_timestamp) / 86400 ))
        fi
    fi
    
    # Calculate repository age
    local repo_age_days=0
    if [ -n "$created_at" ] && [ "$created_at" != "null" ]; then
        local created_timestamp=$(date -d "$created_at" +%s)
        local current_timestamp=$(date +%s)
        repo_age_days=$(( (current_timestamp - created_timestamp) / 86400 ))
    fi
    
    # Determine staleness level
    local stale_threshold=${STALE_REPO_THRESHOLD_DAYS:-90}
    local is_stale="false"
    local staleness_level="active"
    
    if [ "$days_since_last_commit" -gt "$stale_threshold" ]; then
        is_stale="true"
        if [ "$days_since_last_commit" -gt 365 ]; then
            staleness_level="very_stale"
        elif [ "$days_since_last_commit" -gt 180 ]; then
            staleness_level="stale"
        else
            staleness_level="inactive"
        fi
    fi
    
    # Get recent activity indicators
    local has_recent_issues="false"
    local has_recent_prs="false"
    
    # Check for recent issues (last 90 days)
    recent_issues_json=$(perform_curl "https://api.github.com/repos/$repo_name/issues?state=all&since=$(date -d '90 days ago' -u +%Y-%m-%dT%H:%M:%SZ)&per_page=1" || echo '[]')
    if [ "$(echo "$recent_issues_json" | jq 'length')" -gt 0 ]; then
        has_recent_issues="true"
    fi
    
    # Check for recent pull requests (last 90 days)
    recent_prs_json=$(perform_curl "https://api.github.com/repos/$repo_name/pulls?state=all&sort=updated&direction=desc&per_page=1" || echo '[]')
    if [ "$(echo "$recent_prs_json" | jq 'length')" -gt 0 ]; then
        local pr_updated_at=$(echo "$recent_prs_json" | jq -r '.[0].updated_at')
        if [ "$pr_updated_at" != "null" ]; then
            local pr_timestamp=$(date -d "$pr_updated_at" +%s)
            local ninety_days_ago=$(date -d '90 days ago' +%s)
            if [ "$pr_timestamp" -gt "$ninety_days_ago" ]; then
                has_recent_prs="true"
            fi
        fi
    fi
    
    # Determine maintenance status
    local maintenance_status="unknown"
    if [ "$is_archived" = "true" ]; then
        maintenance_status="archived"
    elif [ "$is_disabled" = "true" ]; then
        maintenance_status="disabled"
    elif [ "$days_since_last_commit" -le 30 ]; then
        maintenance_status="actively_maintained"
    elif [ "$days_since_last_commit" -le 90 ]; then
        maintenance_status="occasionally_maintained"
    elif [ "$has_recent_issues" = "true" ] || [ "$has_recent_prs" = "true" ]; then
        maintenance_status="community_activity"
    else
        maintenance_status="unmaintained"
    fi
    
    # Create the result JSON
    cat << EOF
{
    "repository": "$repo_name",
    "is_stale": $is_stale,
    "staleness_level": "$staleness_level",
    "days_since_last_commit": $days_since_last_commit,
    "maintenance_status": "$maintenance_status",
    "repository_info": {
        "description": "$repo_description",
        "language": "$repo_language",
        "size_kb": $repo_size,
        "stars": $stars,
        "forks": $forks,
        "open_issues": $open_issues,
        "age_days": $repo_age_days,
        "created_at": "$created_at",
        "updated_at": "$updated_at",
        "default_branch": "$default_branch",
        "is_archived": $is_archived,
        "is_disabled": $is_disabled,
        "visibility": "$visibility"
    },
    "last_commit": {
        "sha": "$last_commit_sha",
        "message": "$last_commit_message",
        "author": "$last_commit_author",
        "date": "$last_commit_date"
    },
    "recent_activity": {
        "has_recent_issues": $has_recent_issues,
        "has_recent_prs": $has_recent_prs
    }
}
EOF
}

echo "Identifying stale repositories across specified repositories..." >&2

# Get repositories to analyze
repositories=$(get_repositories_to_analyze)

# Initialize results
all_results="[]"
stale_count=0
total_count=0

# Process each repository
while IFS= read -r repo_name; do
    if [ -n "$repo_name" ]; then
        total_count=$((total_count + 1))
        
        # Check repository staleness
        repo_analysis=$(check_repository_staleness "$repo_name")
        
        # Check if this repository is stale
        is_stale=$(echo "$repo_analysis" | jq -r '.is_stale')
        if [ "$is_stale" = "true" ]; then
            stale_count=$((stale_count + 1))
        fi
        
        # Add to results array
        all_results=$(echo "$all_results [$repo_analysis]" | jq -s 'add')
        
        # Rate limiting protection
        sleep 0.3
    fi
done <<< "$repositories"

# Calculate summary statistics
stale_percentage=0
if [ "$total_count" -gt 0 ]; then
    stale_percentage=$(echo "scale=2; ($stale_count * 100) / $total_count" | bc -l)
fi

# Create summary
summary_json=$(cat << EOF
{
    "total_repositories": $total_count,
    "stale_repositories": $stale_count,
    "active_repositories": $((total_count - stale_count)),
    "stale_percentage": $stale_percentage,
    "stale_threshold_days": ${STALE_REPO_THRESHOLD_DAYS:-90},
    "analysis_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

# Create the final output
final_output=$(echo "$all_results $summary_json" | jq -s '{
    "summary": .[1],
    "repositories": .[0]
}')

echo "$final_output"
