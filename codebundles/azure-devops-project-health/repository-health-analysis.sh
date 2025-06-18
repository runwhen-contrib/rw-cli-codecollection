#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# This script:
#   1) Analyzes repository commit patterns
#   2) Checks branch health and protection
#   3) Reviews pull request status
#   4) Identifies potential repository issues
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"

OUTPUT_FILE="repository_health_analysis.json"
analysis_json='[]'

echo "Repository Health Analysis..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

# Get list of repositories
echo "Getting repositories in project..."
if ! repos=$(az repos list --output json 2>repos_err.log); then
    err_msg=$(cat repos_err.log)
    rm -f repos_err.log
    
    echo "ERROR: Could not list repositories."
    analysis_json=$(echo "$analysis_json" | jq \
        --arg title "Failed to List Repositories" \
        --arg details "$err_msg" \
        --arg severity "3" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber)
        }]')
    echo "$analysis_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f repos_err.log

echo "$repos" > repos.json
repo_count=$(jq '. | length' repos.json)

if [ "$repo_count" -eq 0 ]; then
    echo "No repositories found in project."
    analysis_json='[{"title": "No Repositories Found", "details": "No repositories found in the project", "severity": 2}]'
    echo "$analysis_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "Found $repo_count repositories. Analyzing..."

# Analyze each repository
for ((i=0; i<repo_count; i++)); do
    repo_json=$(jq -c ".[${i}]" repos.json)
    
    repo_id=$(echo "$repo_json" | jq -r '.id')
    repo_name=$(echo "$repo_json" | jq -r '.name')
    default_branch=$(echo "$repo_json" | jq -r '.defaultBranch // "main"' | sed 's|refs/heads/||')
    repo_size=$(echo "$repo_json" | jq -r '.size // 0')
    
    echo "Analyzing repository: $repo_name"
    
    # Get recent commit activity (last 7 days)
    from_date=$(date -d "7 days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "  Checking recent commit activity..."
    
    if recent_commits=$(az repos commit list --repository "$repo_name" --query "[?author.date >= '$from_date']" --output json 2>commits_err.log); then
        commit_count=$(echo "$recent_commits" | jq '. | length')
        
        if [ "$commit_count" -gt 0 ]; then
            # Analyze commit patterns
            unique_authors=$(echo "$recent_commits" | jq -r '.[].author.name' | sort -u | wc -l)
            avg_commits_per_day=$(echo "scale=1; $commit_count / 7" | bc -l 2>/dev/null || echo "0")
            
            # Get most active author
            most_active_author=$(echo "$recent_commits" | jq -r '.[].author.name' | sort | uniq -c | sort -nr | head -1 | awk '{print $2" "$3" "$4}' | sed 's/^ *//')
            
            echo "    Recent activity: $commit_count commits by $unique_authors authors"
        else
            unique_authors=0
            avg_commits_per_day="0"
            most_active_author="None"
            echo "    No recent commit activity"
        fi
    else
        echo "    Warning: Could not get recent commits"
        commit_count=0
        unique_authors=0
        avg_commits_per_day="0"
        most_active_author="Unknown"
    fi
    rm -f commits_err.log
    
    # Check pull request status
    echo "  Checking pull request status..."
    if open_prs=$(az repos pr list --repository "$repo_name" --status active --output json 2>pr_err.log); then
        open_pr_count=$(echo "$open_prs" | jq '. | length')
        
        if [ "$open_pr_count" -gt 0 ]; then
            # Analyze PR age
            old_prs=$(echo "$open_prs" | jq --arg old_date "$(date -d '14 days ago' -u +"%Y-%m-%dT%H:%M:%SZ")" '[.[] | select(.creationDate < $old_date)] | length')
            echo "    Open PRs: $open_pr_count (${old_prs} older than 14 days)"
        else
            old_prs=0
            echo "    No open pull requests"
        fi
    else
        echo "    Warning: Could not get pull request status"
        open_pr_count=0
        old_prs=0
    fi
    rm -f pr_err.log
    
    # Check branch policies
    echo "  Checking branch policies..."
    if branch_policies=$(az repos policy list --repository-id "$repo_id" --branch "$default_branch" --output json 2>policy_err.log); then
        policy_count=$(echo "$branch_policies" | jq '. | length')
        enabled_policies=$(echo "$branch_policies" | jq '[.[] | select(.isEnabled == true)] | length')
        echo "    Branch policies: $enabled_policies enabled out of $policy_count total"
    else
        echo "    Warning: Could not get branch policies"
        policy_count=0
        enabled_policies=0
    fi
    rm -f policy_err.log
    
    # Determine health status and issues
    issues_found=()
    severity=1
    
    # Check for low activity
    if [ "$commit_count" -eq 0 ]; then
        issues_found+=("No commits in last 7 days")
        severity=2
    elif [ "$commit_count" -lt 3 ] && [ "$unique_authors" -eq 1 ]; then
        issues_found+=("Low commit activity (only $commit_count commits by 1 author)")
        severity=2
    fi
    
    # Check for stale PRs
    if [ "$old_prs" -gt 0 ]; then
        issues_found+=("$old_prs pull requests older than 14 days")
        severity=2
    fi
    
    # Check for missing branch protection
    if [ "$enabled_policies" -eq 0 ]; then
        issues_found+=("No branch protection policies enabled")
        severity=2
    fi
    
    # Check for very large repositories
    if [ "$repo_size" -gt 1000000000 ]; then  # 1GB
        repo_size_mb=$((repo_size / 1024 / 1024))
        issues_found+=("Large repository size: ${repo_size_mb}MB")
        severity=2
    fi
    
    # Build analysis summary
    if [ ${#issues_found[@]} -eq 0 ]; then
        issues_summary="Repository appears healthy"
        title="Repository Health: $repo_name - Healthy"
    else
        issues_summary=$(IFS='; '; echo "${issues_found[*]}")
        title="Repository Health: $repo_name - Issues Found"
    fi
    
    analysis_json=$(echo "$analysis_json" | jq \
        --arg title "$title" \
        --arg repo_name "$repo_name" \
        --arg repo_id "$repo_id" \
        --arg default_branch "$default_branch" \
        --arg repo_size "$repo_size" \
        --arg commit_count "$commit_count" \
        --arg unique_authors "$unique_authors" \
        --arg avg_commits_per_day "$avg_commits_per_day" \
        --arg most_active_author "$most_active_author" \
        --arg open_pr_count "$open_pr_count" \
        --arg old_prs "$old_prs" \
        --arg policy_count "$policy_count" \
        --arg enabled_policies "$enabled_policies" \
        --arg issues_summary "$issues_summary" \
        --arg severity "$severity" \
        '. += [{
           "title": $title,
           "repo_name": $repo_name,
           "repo_id": $repo_id,
           "default_branch": $default_branch,
           "repo_size_bytes": ($repo_size | tonumber),
           "recent_commits": ($commit_count | tonumber),
           "unique_authors": ($unique_authors | tonumber),
           "avg_commits_per_day": $avg_commits_per_day,
           "most_active_author": $most_active_author,
           "open_prs": ($open_pr_count | tonumber),
           "stale_prs": ($old_prs | tonumber),
           "total_policies": ($policy_count | tonumber),
           "enabled_policies": ($enabled_policies | tonumber),
           "issues_summary": $issues_summary,
           "severity": ($severity | tonumber),
           "details": "Repository \($repo_name): \($commit_count) commits in 7 days by \($unique_authors) authors. \($open_pr_count) open PRs (\($old_prs) stale). \($enabled_policies)/\($policy_count) policies enabled. Issues: \($issues_summary)"
         }]')
done

# Clean up temporary files
rm -f repos.json

# Write final JSON
echo "$analysis_json" > "$OUTPUT_FILE"
echo "Repository health analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== REPOSITORY HEALTH SUMMARY ==="
echo "$analysis_json" | jq -r '.[] | "Repository: \(.repo_name)\nRecent Commits: \(.recent_commits) by \(.unique_authors) authors\nOpen PRs: \(.open_prs) (\(.stale_prs) stale)\nPolicies: \(.enabled_policies)/\(.total_policies) enabled\nIssues: \(.issues_summary)\n---"' 