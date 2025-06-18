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
#   1) Analyzes repository security configuration
#   2) Checks branch protection policies
#   3) Identifies access control misconfigurations
#   4) Detects potential security vulnerabilities
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"

OUTPUT_FILE="repository_security_analysis.json"
security_json='[]'

echo "Analyzing Repository Security Configuration..."
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
    security_json=$(echo "$security_json" | jq \
        --arg title "Cannot Access Repository" \
        --arg details "Failed to access repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "4" \
        --arg next_steps "Verify repository name and permissions to access repository information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$security_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f repo_err.log

repo_id=$(echo "$repo_info" | jq -r '.id')
default_branch=$(echo "$repo_info" | jq -r '.defaultBranch // "refs/heads/main"')
repo_size=$(echo "$repo_info" | jq -r '.size // 0')

echo "Repository ID: $repo_id"
echo "Default Branch: $default_branch"
echo "Repository Size: $repo_size bytes"

# Check branch policies for the default branch
echo "Checking branch protection policies..."
if branch_policies=$(az repos policy list --repository-id "$repo_id" --output json 2>/dev/null); then
    policy_count=$(echo "$branch_policies" | jq '. | length')
    enabled_policies=$(echo "$branch_policies" | jq '[.[] | select(.isEnabled == true)] | length')
    
    echo "Found $policy_count policies, $enabled_policies enabled"
    
    # Check for critical security policies
    required_reviewers=$(echo "$branch_policies" | jq '[.[] | select(.type.displayName == "Minimum number of reviewers" and .isEnabled == true)] | length')
    build_validation=$(echo "$branch_policies" | jq '[.[] | select(.type.displayName == "Build" and .isEnabled == true)] | length')
    work_item_linking=$(echo "$branch_policies" | jq '[.[] | select(.type.displayName == "Work item linking" and .isEnabled == true)] | length')
    comment_resolution=$(echo "$branch_policies" | jq '[.[] | select(.type.displayName == "Comment requirements" and .isEnabled == true)] | length')
    
    echo "Security policies found:"
    echo "  Required reviewers: $required_reviewers"
    echo "  Build validation: $build_validation"
    echo "  Work item linking: $work_item_linking"
    echo "  Comment resolution: $comment_resolution"
    
    # Flag missing critical policies
    if [ "$required_reviewers" -eq 0 ]; then
        security_json=$(echo "$security_json" | jq \
            --arg title "Missing Required Reviewers Policy" \
            --arg details "Default branch $default_branch has no required reviewers policy - code can be merged without review" \
            --arg severity "3" \
            --arg next_steps "Implement minimum reviewers policy for the default branch to ensure code review before merge" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    if [ "$build_validation" -eq 0 ]; then
        security_json=$(echo "$security_json" | jq \
            --arg title "Missing Build Validation Policy" \
            --arg details "Default branch $default_branch has no build validation policy - untested code can be merged" \
            --arg severity "3" \
            --arg next_steps "Implement build validation policy to ensure code passes tests before merge" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    # Check reviewer policy configuration details
    if [ "$required_reviewers" -gt 0 ]; then
        reviewer_policies=$(echo "$branch_policies" | jq '[.[] | select(.type.displayName == "Minimum number of reviewers" and .isEnabled == true)]')
        
        for ((i=0; i<$(echo "$reviewer_policies" | jq '. | length'); i++)); do
            policy=$(echo "$reviewer_policies" | jq -c ".[$i]")
            min_reviewers=$(echo "$policy" | jq -r '.settings.minimumApproverCount // 1')
            creator_vote_counts=$(echo "$policy" | jq -r '.settings.creatorVoteCounts // true')
            allow_downvotes=$(echo "$policy" | jq -r '.settings.allowDownvotes // true')
            reset_on_source_push=$(echo "$policy" | jq -r '.settings.resetOnSourcePush // true')
            
            if [ "$min_reviewers" -lt 2 ]; then
                security_json=$(echo "$security_json" | jq \
                    --arg title "Insufficient Required Reviewers" \
                    --arg details "Required reviewers policy only requires $min_reviewers reviewer(s) - consider requiring at least 2 for better security" \
                    --arg severity "2" \
                    --arg next_steps "Increase minimum reviewer count to at least 2 for better code review coverage" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "severity": ($severity | tonumber),
                       "next_steps": $next_steps
                     }]')
            fi
            
            if [ "$creator_vote_counts" = "true" ]; then
                security_json=$(echo "$security_json" | jq \
                    --arg title "Creator Can Approve Own Changes" \
                    --arg details "Review policy allows creators to approve their own changes - reduces review effectiveness" \
                    --arg severity "2" \
                    --arg next_steps "Configure review policy to prevent creators from approving their own changes" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "severity": ($severity | tonumber),
                       "next_steps": $next_steps
                     }]')
            fi
            
            if [ "$reset_on_source_push" = "false" ]; then
                security_json=$(echo "$security_json" | jq \
                    --arg title "Reviews Not Reset on New Changes" \
                    --arg details "Review policy does not reset approvals when new changes are pushed - approved code may differ from final merge" \
                    --arg severity "2" \
                    --arg next_steps "Configure review policy to reset approvals when source branch is updated" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "severity": ($severity | tonumber),
                       "next_steps": $next_steps
                     }]')
            fi
        done
    fi
    
else
    security_json=$(echo "$security_json" | jq \
        --arg title "Cannot Access Branch Policies" \
        --arg details "Unable to retrieve branch policies for repository - may indicate permission issues" \
        --arg severity "3" \
        --arg next_steps "Verify permissions to read repository policies and branch protection settings" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check repository permissions and access
echo "Checking repository permissions..."
if repo_permissions=$(az devops security permission list --id "$repo_id" --output json 2>/dev/null); then
    echo "Repository permissions accessible"
    
    # This is a simplified check - in practice, you'd analyze specific permission patterns
    permission_count=$(echo "$repo_permissions" | jq '. | length')
    
    if [ "$permission_count" -gt 50 ]; then
        security_json=$(echo "$security_json" | jq \
            --arg title "Excessive Repository Permissions" \
            --arg details "Repository has $permission_count permission entries - may indicate over-permissioning" \
            --arg severity "2" \
            --arg next_steps "Review repository permissions and remove unnecessary access grants" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
else
    echo "Cannot access detailed repository permissions"
fi

# Check for sensitive files in repository (basic check)
echo "Checking for potential sensitive files..."
if files=$(az repos list --output json 2>/dev/null); then
    # This is a placeholder - in practice, you'd clone the repo and scan for sensitive patterns
    # For now, we'll check repository name and size for indicators
    
    if [[ "$AZURE_DEVOPS_REPO" =~ (config|secret|key|password|credential) ]]; then
        security_json=$(echo "$security_json" | jq \
            --arg title "Repository Name Contains Sensitive Keywords" \
            --arg details "Repository name '$AZURE_DEVOPS_REPO' contains keywords that might indicate sensitive content" \
            --arg severity "2" \
            --arg next_steps "Review repository contents for accidentally committed secrets or sensitive information" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    # Check repository size for potential issues
    if [ "$repo_size" -gt 104857600 ]; then  # 100MB
        size_mb=$(echo "scale=1; $repo_size / 1048576" | bc -l 2>/dev/null || echo "unknown")
        security_json=$(echo "$security_json" | jq \
            --arg title "Large Repository Size" \
            --arg details "Repository size is ${size_mb}MB - may contain large files or binaries that should use Git LFS" \
            --arg severity "1" \
            --arg next_steps "Review repository for large files, consider using Git LFS for binaries, and check for accidentally committed files" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Check for default branch protection
echo "Verifying default branch protection..."
if [[ "$default_branch" == "refs/heads/main" ]] || [[ "$default_branch" == "refs/heads/master" ]]; then
    echo "Default branch is $default_branch"
    
    if [ "$enabled_policies" -eq 0 ]; then
        security_json=$(echo "$security_json" | jq \
            --arg title "Unprotected Default Branch" \
            --arg details "Default branch $default_branch has no protection policies - direct pushes are allowed" \
            --arg severity "4" \
            --arg next_steps "Implement branch protection policies for the default branch to prevent direct pushes and require reviews" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
else
    security_json=$(echo "$security_json" | jq \
        --arg title "Non-Standard Default Branch" \
        --arg details "Default branch is '$default_branch' - consider using standard naming (main/master)" \
        --arg severity "1" \
        --arg next_steps "Consider renaming default branch to 'main' for consistency with modern Git practices" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# If no security issues found, add a healthy status
if [ "$(echo "$security_json" | jq '. | length')" -eq 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Repository Security: Well Configured" \
        --arg details "Repository security settings appear to be properly configured with appropriate branch protection" \
        --arg severity "1" \
        --arg next_steps "Continue monitoring security settings and review policies periodically" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$security_json" > "$OUTPUT_FILE"
echo "Repository security analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== REPOSITORY SECURITY SUMMARY ==="
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Branch Policies: $enabled_policies enabled out of $policy_count total"
echo "Default Branch: $default_branch"
echo ""
echo "$security_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 