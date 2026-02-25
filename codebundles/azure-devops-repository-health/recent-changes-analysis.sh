#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#   AZURE_DEVOPS_REPO
#   ANALYSIS_DAYS (optional, default: 7)
#
# This script:
#   1) Analyzes recent commits that might be causing application failures
#   2) Identifies risky commits (large changes, configuration changes, etc.)
#   3) Checks for recent releases and deployments
#   4) Flags potentially problematic changes for troubleshooting
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"
: "${ANALYSIS_DAYS:=7}"

OUTPUT_FILE="recent_changes_analysis.json"
changes_json='[]'

echo "Analyzing Recent Code Changes for Troubleshooting..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project: $AZURE_DEVOPS_PROJECT"
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Analysis Period: Last $ANALYSIS_DAYS days"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

# Calculate date range for analysis
from_date=$(date -d "$ANALYSIS_DAYS days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Analyzing changes since: $from_date"

# Get repository information
echo "Getting repository information..."
if ! repo_info=$(az repos show --repository "$AZURE_DEVOPS_REPO" --output json 2>repo_err.log); then
    err_msg=$(cat repo_err.log)
    rm -f repo_err.log
    
    echo "ERROR: Could not get repository information."
    changes_json=$(echo "$changes_json" | jq \
        --arg title "Cannot Access Repository for Recent Changes Analysis" \
        --arg details "Failed to access repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify repository name and permissions to access repository information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$changes_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f repo_err.log

repo_id=$(echo "$repo_info" | jq -r '.id')
default_branch=$(echo "$repo_info" | jq -r '.defaultBranch // "refs/heads/main"' | sed 's|refs/heads/||')

echo "Repository ID: $repo_id"
echo "Default Branch: $default_branch"

# Get recent commits
echo "Analyzing recent commits..."
if recent_commits=$(az repos commit list --repository "$AZURE_DEVOPS_REPO" --query "[?author.date >= '$from_date']" --output json 2>commits_err.log); then
    commit_count=$(echo "$recent_commits" | jq '. | length')
    echo "Found $commit_count recent commits"
    
    if [ "$commit_count" -eq 0 ]; then
        changes_json=$(echo "$changes_json" | jq \
            --arg title "No Recent Commits Found" \
            --arg details "No commits found in the last $ANALYSIS_DAYS days - application issues may not be related to recent code changes" \
            --arg severity "1" \
            --arg next_steps "Check if issues are related to external dependencies, infrastructure, or configuration changes outside the repository" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    else
        # Analyze commit patterns for troubleshooting flags
        large_commits=0
        config_changes=0
        critical_file_changes=0
        rollback_commits=0
        emergency_commits=0
        
        # Track commit authors and timing
        commit_authors=()
        commit_times=()
        
        for ((i=0; i<commit_count; i++)); do
            commit_json=$(echo "$recent_commits" | jq -c ".[$i]")
            commit_id=$(echo "$commit_json" | jq -r '.commitId')
            commit_message=$(echo "$commit_json" | jq -r '.comment')
            author_name=$(echo "$commit_json" | jq -r '.author.name')
            commit_time=$(echo "$commit_json" | jq -r '.author.date')
            change_count=$(echo "$commit_json" | jq -r '.changeCounts.Edit // 0')
            
            # Store for pattern analysis
            commit_authors+=("$author_name")
            commit_times+=("$commit_time")
            
            # Analyze commit message for risk indicators
            if [[ "$commit_message" =~ [Rr]ollback|[Rr]evert|[Ff]ix.*prod|[Hh]otfix|[Ee]mergency|[Uu]rgent ]]; then
                emergency_commits=$((emergency_commits + 1))
                
                changes_json=$(echo "$changes_json" | jq \
                    --arg title "Emergency/Rollback Commit Detected" \
                    --arg details "Emergency commit found: '$commit_message' by $author_name at $commit_time (Commit: ${commit_id:0:8})" \
                    --arg severity "3" \
                    --arg next_steps "Review this emergency commit as it may be related to the current application issues. Check if the fix was complete or if additional issues were introduced." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "severity": ($severity | tonumber),
                       "next_steps": $next_steps
                     }]')
            fi
            
            # Check for configuration file changes (common source of issues)
            if [[ "$commit_message" =~ [Cc]onfig|[Ss]ettings|[Ee]nvironment|\.config|\.json|\.yaml|\.yml|\.properties|\.xml ]]; then
                config_changes=$((config_changes + 1))
            fi
            
            # Check for large commits (might indicate rushed changes)
            if [ "$change_count" -gt 50 ]; then
                large_commits=$((large_commits + 1))
            fi
        done
        
        # Report on large commits
        if [ "$large_commits" -gt 0 ]; then
            changes_json=$(echo "$changes_json" | jq \
                --arg title "Large Commits Detected in Recent Changes" \
                --arg details "$large_commits commits with >50 file changes detected in the last $ANALYSIS_DAYS days - large commits may introduce multiple issues" \
                --arg severity "2" \
                --arg next_steps "Review large commits for potential issues. Consider breaking down future changes into smaller, more manageable commits." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "severity": ($severity | tonumber),
                   "next_steps": $next_steps
                 }]')
        fi
        
        # Report on configuration changes
        if [ "$config_changes" -gt 0 ]; then
            changes_json=$(echo "$changes_json" | jq \
                --arg title "Configuration Changes Detected" \
                --arg details "$config_changes commits containing configuration changes in the last $ANALYSIS_DAYS days - configuration changes are common sources of application issues" \
                --arg severity "2" \
                --arg next_steps "Review configuration changes carefully. Check if environment-specific settings are correct and if all required configuration values are properly set." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "severity": ($severity | tonumber),
                   "next_steps": $next_steps
                 }]')
        fi
        
        # Analyze commit frequency (too many commits might indicate panic fixes)
        commits_per_day=$(echo "scale=1; $commit_count / $ANALYSIS_DAYS" | bc -l 2>/dev/null || echo "0")
        if (( $(echo "$commits_per_day > 10" | bc -l 2>/dev/null || echo "0") )); then
            changes_json=$(echo "$changes_json" | jq \
                --arg title "High Commit Frequency Detected" \
                --arg details "High commit frequency: $commits_per_day commits per day - may indicate urgent fixes or unstable code" \
                --arg severity "2" \
                --arg next_steps "High commit frequency may indicate reactive bug fixing. Review recent commits for quality and consider if rushed changes introduced new issues." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "severity": ($severity | tonumber),
                   "next_steps": $next_steps
                 }]')
        fi
        
        # Get unique authors count
        unique_authors=$(printf '%s\n' "${commit_authors[@]}" | sort -u | wc -l)
        
        # Single author making many changes might indicate pressure/urgency
        if [ "$unique_authors" -eq 1 ] && [ "$commit_count" -gt 5 ]; then
            main_author=$(printf '%s\n' "${commit_authors[@]}" | head -1)
            changes_json=$(echo "$changes_json" | jq \
                --arg title "Single Author Making Multiple Recent Changes" \
                --arg details "Single author ($main_author) made $commit_count commits in $ANALYSIS_DAYS days - may indicate urgent fixes or team availability issues" \
                --arg severity "1" \
                --arg next_steps "Consider if the changes were rushed or if proper code review processes were followed. Ensure team knowledge sharing for critical changes." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "severity": ($severity | tonumber),
                   "next_steps": $next_steps
                 }]')
        fi
    fi
else
    err_msg=$(cat commits_err.log)
    rm -f commits_err.log
    
    changes_json=$(echo "$changes_json" | jq \
        --arg title "Cannot Access Recent Commits" \
        --arg details "Failed to retrieve recent commits: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify permissions to read repository commit history" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi
rm -f commits_err.log

# Check for recent releases/tags
echo "Checking for recent releases..."
if recent_tags=$(az repos ref list --repository "$AZURE_DEVOPS_REPO" --filter "tags/" --output json 2>/dev/null); then
    recent_releases=()
    
    for ((i=0; i<$(echo "$recent_tags" | jq '. | length'); i++)); do
        tag_json=$(echo "$recent_tags" | jq -c ".[$i]")
        tag_name=$(echo "$tag_json" | jq -r '.name' | sed 's|refs/tags/||')
        
        # This is a simplified check - in practice, you'd get creation date from commit info
        recent_releases+=("$tag_name")
    done
    
    if [ ${#recent_releases[@]} -gt 0 ]; then
        release_list=$(printf '%s\n' "${recent_releases[@]}" | head -5 | tr '\n' ',' | sed 's/,$//')
        changes_json=$(echo "$changes_json" | jq \
            --arg title "Recent Releases/Tags Found" \
            --arg details "Recent releases detected: $release_list - check if application issues correlate with recent releases" \
            --arg severity "1" \
            --arg next_steps "Compare application issue timeline with release dates. Consider if recent releases introduced breaking changes or if rollback is needed." \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Check for pull requests merged recently
echo "Checking recent pull request activity..."
if recent_prs=$(az repos pr list --repository "$AZURE_DEVOPS_REPO" --status completed --output json 2>/dev/null); then
    # Filter PRs closed in the analysis period
    recent_merged_count=0
    large_pr_count=0
    
    for ((i=0; i<$(echo "$recent_prs" | jq '. | length') && i<10; i++)); do
        pr_json=$(echo "$recent_prs" | jq -c ".[$i]")
        closed_date=$(echo "$pr_json" | jq -r '.closedDate // empty')
        
        if [ -n "$closed_date" ]; then
            # Convert closed date to timestamp for comparison
            closed_ts=$(date -d "$closed_date" +%s 2>/dev/null || echo "0")
            from_ts=$(date -d "$from_date" +%s 2>/dev/null || echo "0")
            
            if [ "$closed_ts" -gt "$from_ts" ]; then
                recent_merged_count=$((recent_merged_count + 1))
                
                pr_title=$(echo "$pr_json" | jq -r '.title')
                
                # Check for large PRs or urgent language
                if [[ "$pr_title" =~ [Uu]rgent|[Hh]otfix|[Ee]mergency|[Cc]ritical ]]; then
                    changes_json=$(echo "$changes_json" | jq \
                        --arg title "Urgent Pull Request Merged Recently" \
                        --arg details "Urgent PR merged: '$pr_title' - may be related to current application issues" \
                        --arg severity "2" \
                        --arg next_steps "Review the urgent PR changes and verify if the fix was complete or introduced new issues" \
                        '. += [{
                           "title": $title,
                           "details": $details,
                           "severity": ($severity | tonumber),
                           "next_steps": $next_steps
                         }]')
                fi
            fi
        fi
    done
    
    if [ "$recent_merged_count" -gt 3 ]; then
        changes_json=$(echo "$changes_json" | jq \
            --arg title "High Pull Request Merge Activity" \
            --arg details "$recent_merged_count PRs merged in the last $ANALYSIS_DAYS days - high merge activity may indicate instability" \
            --arg severity "1" \
            --arg next_steps "Review recently merged PRs for potential issues. Consider if the development pace is sustainable and if proper testing was conducted." \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# If no issues found, provide a summary
if [ "$(echo "$changes_json" | jq '. | length')" -eq 0 ]; then
    changes_json=$(echo "$changes_json" | jq \
        --arg title "Recent Changes Analysis Complete" \
        --arg details "No obvious risk indicators found in recent code changes. Application issues may be related to external factors, infrastructure, or dependencies." \
        --arg severity "1" \
        --arg next_steps "Look beyond code changes: check infrastructure, external services, configuration outside the repository, and deployment processes." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$changes_json" > "$OUTPUT_FILE"
echo "Recent changes analysis completed. Results saved to $OUTPUT_FILE"

# Output summary
echo ""
echo "=== RECENT CHANGES SUMMARY FOR TROUBLESHOOTING ==="
echo "Analysis Period: Last $ANALYSIS_DAYS days"
echo "$changes_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\nNext Steps: \(.next_steps)\n---"' 