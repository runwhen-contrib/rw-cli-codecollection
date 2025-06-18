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
#   4) Detects potential security vulnerabilities with clustered reporting
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"

OUTPUT_FILE="repository_security_analysis.json"
security_json='[]'

# Issue tracking arrays (for potential clustering if multiple repos analyzed)
missing_reviewer_policies=()
missing_build_validation=()
insufficient_reviewers=()
creator_can_approve=()
reviews_not_reset=()
unprotected_default_branch=()
non_standard_branch_name=()
large_repositories=()
sensitive_named_repos=()

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
        --arg title "Cannot Access Repository \`$AZURE_DEVOPS_REPO\` in Project \`$AZURE_DEVOPS_PROJECT\`" \
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
    
    # Flag missing critical policies (best practices - severity 4)
    if [ "$required_reviewers" -eq 0 ]; then
        missing_reviewer_policies+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO")
    fi
    
    if [ "$build_validation" -eq 0 ]; then
        missing_build_validation+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO")
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
                insufficient_reviewers+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO (has $min_reviewers)")
            fi
            
            if [ "$creator_vote_counts" = "true" ]; then
                creator_can_approve+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO")
            fi
            
            if [ "$reset_on_source_push" = "false" ]; then
                reviews_not_reset+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO")
            fi
        done
    fi
    
else
    security_json=$(echo "$security_json" | jq \
        --arg title "Cannot Access Branch Policies for Repository \`$AZURE_DEVOPS_REPO\`" \
        --arg details "Unable to retrieve branch policies for repository in project \`$AZURE_DEVOPS_PROJECT\` - may indicate permission issues" \
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
            --arg title "Excessive Repository Permissions for \`$AZURE_DEVOPS_REPO\`" \
            --arg details "Repository has $permission_count permission entries - may indicate over-permissioning" \
            --arg severity "4" \
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
        sensitive_named_repos+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO")
    fi
    
    # Check repository size for potential issues
    if [ "$repo_size" -gt 104857600 ]; then  # 100MB
        size_mb=$(echo "scale=1; $repo_size / 1048576" | bc -l 2>/dev/null || echo "unknown")
        large_repositories+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO (${size_mb}MB)")
    fi
fi

# Check for default branch protection
echo "Verifying default branch protection..."
if [[ "$default_branch" == "refs/heads/main" ]] || [[ "$default_branch" == "refs/heads/master" ]]; then
    echo "Default branch is $default_branch"
    
    if [ "$enabled_policies" -eq 0 ]; then
        unprotected_default_branch+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO ($default_branch)")
    fi
else
    non_standard_branch_name+=("$AZURE_DEVOPS_PROJECT/$AZURE_DEVOPS_REPO ($default_branch)")
fi

# Generate issues based on collected data
if [ ${#missing_reviewer_policies[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Missing Required Reviewers Policy" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` lacks required reviewers policy - code can be merged without review (best practice)" \
        --arg severity "4" \
        --arg next_steps "Implement minimum reviewers policy for the default branch to ensure code review before merge" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#missing_build_validation[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Missing Build Validation Policy" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` lacks build validation policy - untested code can be merged (best practice)" \
        --arg severity "4" \
        --arg next_steps "Implement build validation policy to ensure code passes tests before merge" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#insufficient_reviewers[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Insufficient Required Reviewers" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` has insufficient reviewer requirements - consider requiring at least 2 for better security (best practice)" \
        --arg severity "4" \
        --arg next_steps "Increase minimum reviewer count to at least 2 for better code review coverage" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#creator_can_approve[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Creator Can Approve Own Changes" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` allows creators to approve their own changes - reduces review effectiveness (best practice)" \
        --arg severity "4" \
        --arg next_steps "Configure review policy to prevent creators from approving their own changes" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#reviews_not_reset[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Reviews Not Reset on New Changes" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` does not reset approvals when new changes are pushed - approved code may differ from final merge (best practice)" \
        --arg severity "4" \
        --arg next_steps "Configure review policy to reset approvals when source branch is updated" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#unprotected_default_branch[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Unprotected Default Branch" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` has an unprotected default branch - direct pushes are allowed (security risk)" \
        --arg severity "3" \
        --arg next_steps "Implement branch protection policies for the default branch to prevent direct pushes and require reviews" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#non_standard_branch_name[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Non-Standard Default Branch Name" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` uses non-standard default branch name '$default_branch' - consider using standard naming (best practice)" \
        --arg severity "4" \
        --arg next_steps "Consider renaming default branch to 'main' for consistency with modern Git practices" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#large_repositories[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Large Repository Size" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` is large - may contain large files or binaries that should use Git LFS (best practice)" \
        --arg severity "4" \
        --arg next_steps "Review repository for large files, consider using Git LFS for binaries, and check for accidentally committed files" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#sensitive_named_repos[@]} -gt 0 ]; then
    security_json=$(echo "$security_json" | jq \
        --arg title "Repository Name Contains Sensitive Keywords" \
        --arg details "Repository \`$AZURE_DEVOPS_REPO\` in project \`$AZURE_DEVOPS_PROJECT\` contains keywords that might indicate sensitive content (security review)" \
        --arg severity "3" \
        --arg next_steps "Review repository contents for accidentally committed secrets or sensitive information" \
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
        --arg title "Repository Security: Well Configured (\`$AZURE_DEVOPS_REPO\`)" \
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