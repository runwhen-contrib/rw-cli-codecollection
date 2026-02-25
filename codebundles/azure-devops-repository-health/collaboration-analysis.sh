#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#   AZURE_DEVOPS_REPO
#
# This script:
#   1) Analyzes pull request patterns and health
#   2) Examines code review practices
#   3) Identifies collaboration bottlenecks
#   4) Detects team workflow issues
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"

OUTPUT_FILE="collaboration_analysis.json"
collaboration_json='[]'

echo "Analyzing Collaboration and Pull Request Patterns..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project: $AZURE_DEVOPS_PROJECT"
echo "Repository: $AZURE_DEVOPS_REPO"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

# Get repository information
echo "Getting repository information..."
if ! repo_info=$(az repos show --repository "$AZURE_DEVOPS_REPO" --output json 2>repo_err.log); then
    err_msg=$(cat repo_err.log)
    rm -f repo_err.log
    
    echo "ERROR: Could not get repository information."
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "Cannot Access Repository for Collaboration Analysis" \
        --arg details "Failed to access repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify repository name and permissions to access repository information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$collaboration_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f repo_err.log

repo_id=$(echo "$repo_info" | jq -r '.id')

# Get pull requests (last 30 days)
echo "Getting pull request information..."
thirty_days_ago=$(date -d "30 days ago" -u +"%Y-%m-%dT%H:%M:%SZ")

if ! pull_requests=$(az repos pr list --repository "$AZURE_DEVOPS_REPO" --status all --output json 2>pr_err.log); then
    err_msg=$(cat pr_err.log)
    rm -f pr_err.log
    
    echo "WARNING: Could not get pull request information."
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "Cannot Access Pull Request Information" \
        --arg details "Failed to get pull requests for repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "2" \
        --arg next_steps "Verify permissions to read pull request information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$collaboration_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f pr_err.log

echo "$pull_requests" > pull_requests.json
pr_count=$(jq '. | length' pull_requests.json)

echo "Found $pr_count pull requests"

if [ "$pr_count" -eq 0 ]; then
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "No Pull Requests Found" \
        --arg details "Repository has no pull requests - may indicate direct commits to main branch or inactive repository" \
        --arg severity "2" \
        --arg next_steps "Implement pull request workflow to improve code review and collaboration practices" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$collaboration_json" > "$OUTPUT_FILE"
    exit 0
fi

# Analyze pull request patterns
echo "Analyzing pull request patterns..."

# Initialize counters
active_prs=0
completed_prs=0
abandoned_prs=0
draft_prs=0
large_prs=0
quick_merges=0
long_lived_prs=0
self_approved_prs=0
no_review_prs=0

# Track contributors
declare -A contributors
declare -A reviewers

# Analyze each pull request
for ((i=0; i<pr_count; i++)); do
    pr_json=$(jq -c ".[${i}]" pull_requests.json)
    
    pr_id=$(echo "$pr_json" | jq -r '.pullRequestId')
    pr_status=$(echo "$pr_json" | jq -r '.status')
    pr_title=$(echo "$pr_json" | jq -r '.title')
    created_by=$(echo "$pr_json" | jq -r '.createdBy.displayName // "unknown"')
    created_date=$(echo "$pr_json" | jq -r '.creationDate')
    is_draft=$(echo "$pr_json" | jq -r '.isDraft // false')
    
    echo "  Analyzing PR #$pr_id: $pr_title"
    
    # Count by status
    case "$pr_status" in
        "active")
            active_prs=$((active_prs + 1))
            ;;
        "completed")
            completed_prs=$((completed_prs + 1))
            ;;
        "abandoned")
            abandoned_prs=$((abandoned_prs + 1))
            ;;
    esac
    
    # Count draft PRs
    if [ "$is_draft" = "true" ]; then
        draft_prs=$((draft_prs + 1))
    fi
    
    # Track contributors
    contributors["$created_by"]=$((${contributors["$created_by"]:-0} + 1))
    
    # Check PR age for long-lived PRs
    if [ "$pr_status" = "active" ]; then
        created_timestamp=$(date -d "$created_date" +%s 2>/dev/null || echo "0")
        current_timestamp=$(date +%s)
        age_days=$(( (current_timestamp - created_timestamp) / 86400 ))
        
        if [ "$age_days" -gt 14 ]; then
            long_lived_prs=$((long_lived_prs + 1))
        fi
    fi
    
    # Get detailed PR information for review analysis
    if pr_details=$(az repos pr show --id "$pr_id" --output json 2>/dev/null); then
        # Check for reviewers
        reviewers_list=$(echo "$pr_details" | jq -r '.reviewers[]?.displayName // empty' 2>/dev/null || echo "")
        reviewer_count=$(echo "$reviewers_list" | wc -l)
        
        if [ -z "$reviewers_list" ] || [ "$reviewer_count" -eq 0 ]; then
            no_review_prs=$((no_review_prs + 1))
        else
            # Track reviewers
            while IFS= read -r reviewer; do
                if [ -n "$reviewer" ]; then
                    reviewers["$reviewer"]=$((${reviewers["$reviewer"]:-0} + 1))
                    
                    # Check for self-approval
                    if [ "$reviewer" = "$created_by" ]; then
                        self_approved_prs=$((self_approved_prs + 1))
                    fi
                fi
            done <<< "$reviewers_list"
        fi
        
        # Check for quick merges (completed within 1 hour)
        if [ "$pr_status" = "completed" ]; then
            closed_date=$(echo "$pr_details" | jq -r '.closedDate // empty')
            if [ -n "$closed_date" ] && [ -n "$created_date" ]; then
                created_ts=$(date -d "$created_date" +%s 2>/dev/null || echo "0")
                closed_ts=$(date -d "$closed_date" +%s 2>/dev/null || echo "0")
                duration_hours=$(( (closed_ts - created_ts) / 3600 ))
                
                if [ "$duration_hours" -lt 1 ] && [ "$duration_hours" -ge 0 ]; then
                    quick_merges=$((quick_merges + 1))
                fi
            fi
        fi
    fi
done

echo "Pull request analysis results:"
echo "  Active PRs: $active_prs"
echo "  Completed PRs: $completed_prs"
echo "  Abandoned PRs: $abandoned_prs"
echo "  Draft PRs: $draft_prs"
echo "  Long-lived PRs (>14 days): $long_lived_prs"
echo "  Quick merges (<1 hour): $quick_merges"
echo "  Self-approved PRs: $self_approved_prs"
echo "  PRs without reviews: $no_review_prs"

# Analyze contributor patterns
contributor_count=${#contributors[@]}
reviewer_count=${#reviewers[@]}

echo "Collaboration metrics:"
echo "  Contributors: $contributor_count"
echo "  Reviewers: $reviewer_count"

# Generate issues based on analysis
if [ "$abandoned_prs" -gt 0 ]; then
    abandonment_rate=$(echo "scale=1; $abandoned_prs * 100 / $pr_count" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$abandonment_rate >= 20" | bc -l) )); then
        collaboration_json=$(echo "$collaboration_json" | jq \
            --arg title "High Pull Request Abandonment Rate" \
            --arg details "$abandoned_prs out of $pr_count PRs were abandoned (${abandonment_rate}%) - indicates workflow or collaboration issues" \
            --arg severity "3" \
            --arg next_steps "Investigate reasons for PR abandonment, improve PR review process, and provide better guidance for contributors" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

if [ "$long_lived_prs" -gt 0 ]; then
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "Long-Lived Pull Requests" \
        --arg details "$long_lived_prs active PRs have been open for more than 14 days - may indicate review bottlenecks" \
        --arg severity "2" \
        --arg next_steps "Review long-lived PRs, identify review bottlenecks, and consider breaking large changes into smaller PRs" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ "$no_review_prs" -gt 0 ]; then
    no_review_rate=$(echo "scale=1; $no_review_prs * 100 / $pr_count" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$no_review_rate >= 30" | bc -l) )); then
        collaboration_json=$(echo "$collaboration_json" | jq \
            --arg title "High Rate of Unreviewed Pull Requests" \
            --arg details "$no_review_prs out of $pr_count PRs had no reviewers (${no_review_rate}%) - code quality and knowledge sharing may suffer" \
            --arg severity "3" \
            --arg next_steps "Implement required reviewers policy and establish code review guidelines" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

if [ "$self_approved_prs" -gt 0 ]; then
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "Self-Approved Pull Requests" \
        --arg details "$self_approved_prs PRs were approved by their own creators - reduces review effectiveness" \
        --arg severity "2" \
        --arg next_steps "Configure branch policies to prevent self-approval and require external reviewers" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ "$quick_merges" -gt 0 ]; then
    quick_merge_rate=$(echo "scale=1; $quick_merges * 100 / $completed_prs" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$quick_merge_rate >= 40" | bc -l) )); then
        collaboration_json=$(echo "$collaboration_json" | jq \
            --arg title "High Rate of Quick Merges" \
            --arg details "$quick_merges out of $completed_prs completed PRs were merged within 1 hour (${quick_merge_rate}%) - may indicate insufficient review time" \
            --arg severity "2" \
            --arg next_steps "Review quick merge patterns and consider implementing minimum review time requirements for non-trivial changes" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Check for collaboration diversity
if [ "$contributor_count" -eq 1 ] && [ "$pr_count" -gt 5 ]; then
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "Single Contributor Repository" \
        --arg details "All $pr_count PRs come from a single contributor - may indicate lack of team collaboration" \
        --arg severity "1" \
        --arg next_steps "Encourage team collaboration and knowledge sharing through pair programming or code reviews" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ "$reviewer_count" -eq 0 ] && [ "$pr_count" -gt 0 ]; then
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "No Code Reviews" \
        --arg details "Repository has $pr_count PRs but no reviewers - missing code review process" \
        --arg severity "3" \
        --arg next_steps "Establish code review process and assign reviewers to pull requests" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
elif [ "$reviewer_count" -eq 1 ] && [ "$pr_count" -gt 10 ]; then
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "Single Reviewer Bottleneck" \
        --arg details "All reviews are done by a single person - creates review bottleneck and knowledge concentration" \
        --arg severity "2" \
        --arg next_steps "Distribute review responsibilities across team members and cross-train on different areas of the codebase" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check draft PR usage
if [ "$draft_prs" -gt 0 ]; then
    draft_rate=$(echo "scale=1; $draft_prs * 100 / $pr_count" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$draft_rate >= 50" | bc -l) )); then
        collaboration_json=$(echo "$collaboration_json" | jq \
            --arg title "High Rate of Draft Pull Requests" \
            --arg details "$draft_prs out of $pr_count PRs are drafts (${draft_rate}%) - may indicate work-in-progress management issues" \
            --arg severity "1" \
            --arg next_steps "Review draft PR usage patterns and establish guidelines for when to use draft PRs vs feature branches" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Clean up temporary files
rm -f pull_requests.json

# If no collaboration issues found, add a healthy status
if [ "$(echo "$collaboration_json" | jq '. | length')" -eq 0 ]; then
    collaboration_json=$(echo "$collaboration_json" | jq \
        --arg title "Collaboration: Healthy Patterns" \
        --arg details "Pull request and collaboration patterns appear healthy with $pr_count PRs from $contributor_count contributors" \
        --arg severity "1" \
        --arg next_steps "Continue maintaining good collaboration practices and consider ways to further improve code review quality" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$collaboration_json" > "$OUTPUT_FILE"
echo "Collaboration analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== COLLABORATION SUMMARY ==="
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Total PRs: $pr_count"
echo "Contributors: $contributor_count"
echo "Reviewers: $reviewer_count"
echo "Active PRs: $active_prs"
echo "Abandoned PRs: $abandoned_prs"
echo "Long-lived PRs: $long_lived_prs"
echo "Unreviewed PRs: $no_review_prs"
echo ""
echo "$collaboration_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 