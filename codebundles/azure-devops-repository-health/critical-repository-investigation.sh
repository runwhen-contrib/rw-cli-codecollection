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
#   1) Performs deep investigation of critical repository issues
#   2) Analyzes security and configuration problems in detail
#   3) Provides comprehensive troubleshooting information
#   4) Suggests specific remediation steps
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"

echo "Deep Critical Repository Issue Investigation..."
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

echo "=== CRITICAL REPOSITORY INVESTIGATION ==="
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

# Get comprehensive repository information
echo "1. REPOSITORY CONFIGURATION ANALYSIS"
echo "======================================"
if repo_info=$(az repos show --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    echo "Repository Details:"
    echo "  Name: $(echo "$repo_info" | jq -r '.name')"
    echo "  ID: $(echo "$repo_info" | jq -r '.id')"
    echo "  Size: $(echo "$repo_info" | jq -r '.size') bytes"
    echo "  Default Branch: $(echo "$repo_info" | jq -r '.defaultBranch')"
    echo "  Remote URL: $(echo "$repo_info" | jq -r '.remoteUrl')"
    echo "  Project: $(echo "$repo_info" | jq -r '.project.name')"
    
    repo_id=$(echo "$repo_info" | jq -r '.id')
else
    echo "ERROR: Cannot access repository information"
    exit 1
fi

echo ""

# Detailed branch policy analysis
echo "2. BRANCH PROTECTION ANALYSIS"
echo "=============================="
if branch_policies=$(az repos policy list --repository-id "$repo_id" --output json 2>/dev/null); then
    policy_count=$(echo "$branch_policies" | jq '. | length')
    enabled_policies=$(echo "$branch_policies" | jq '[.[] | select(.isEnabled == true)] | length')
    
    echo "Branch Policies Summary:"
    echo "  Total Policies: $policy_count"
    echo "  Enabled Policies: $enabled_policies"
    echo ""
    
    if [ "$enabled_policies" -eq 0 ]; then
        echo "CRITICAL: No branch protection policies enabled!"
        echo "  - Direct pushes to all branches are allowed"
        echo "  - No code review requirements"
        echo "  - No build validation requirements"
        echo ""
    fi
    
    # Analyze each policy type
    echo "Policy Details:"
    for policy_type in "Minimum number of reviewers" "Build" "Work item linking" "Comment requirements"; do
        count=$(echo "$branch_policies" | jq --arg type "$policy_type" '[.[] | select(.type.displayName == $type and .isEnabled == true)] | length')
        echo "  $policy_type: $count enabled"
        
        if [ "$count" -gt 0 ]; then
            echo "$branch_policies" | jq --arg type "$policy_type" -r '.[] | select(.type.displayName == $type and .isEnabled == true) | "    - Scope: \(.settings.scope[0].refName // "All branches")"'
        fi
    done
else
    echo "ERROR: Cannot access branch policies"
fi

echo ""

# Security permissions analysis
echo "3. REPOSITORY PERMISSIONS ANALYSIS"
echo "=================================="
if permissions=$(az devops security permission list --id "$repo_id" --output json 2>/dev/null); then
    permission_count=$(echo "$permissions" | jq '. | length')
    echo "Repository Permissions:"
    echo "  Total Permission Entries: $permission_count"
    
    # This is a simplified analysis - in practice, you'd analyze specific permission patterns
    if [ "$permission_count" -gt 20 ]; then
        echo "WARNING: Large number of permission entries may indicate over-permissioning"
    fi
else
    echo "Cannot access detailed repository permissions"
fi

echo ""

# Recent activity analysis
echo "4. RECENT ACTIVITY ANALYSIS"
echo "==========================="
seven_days_ago=$(date -d "7 days ago" -u +"%Y-%m-%dT%H:%M:%SZ")

# Check recent commits
if commits=$(az repos ref list --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    echo "Recent Repository Activity:"
    echo "  Analyzing commit patterns..."
    
    # This is simplified - in practice, you'd get actual commit history
    echo "  Note: Detailed commit analysis requires repository cloning"
else
    echo "Cannot access commit information"
fi

# Check recent pull requests
if recent_prs=$(az repos pr list --repository "$AZURE_DEVOPS_REPO" --status all --top 10 --output json 2>/dev/null); then
    pr_count=$(echo "$recent_prs" | jq '. | length')
    active_prs=$(echo "$recent_prs" | jq '[.[] | select(.status == "active")] | length')
    abandoned_prs=$(echo "$recent_prs" | jq '[.[] | select(.status == "abandoned")] | length')
    
    echo "Recent Pull Requests (last 10):"
    echo "  Total: $pr_count"
    echo "  Active: $active_prs"
    echo "  Abandoned: $abandoned_prs"
    
    if [ "$abandoned_prs" -gt 0 ]; then
        echo "  WARNING: $abandoned_prs abandoned PRs may indicate workflow issues"
    fi
    
    # Show recent PR details
    echo "  Recent PR Details:"
    echo "$recent_prs" | jq -r '.[] | "    - #\(.pullRequestId): \(.title) (\(.status)) by \(.createdBy.displayName)"' | head -5
else
    echo "Cannot access pull request information"
fi

echo ""

# Build and CI/CD analysis
echo "5. BUILD AND CI/CD ANALYSIS"
echo "==========================="
if builds=$(az pipelines list --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    build_count=$(echo "$builds" | jq '. | length')
    echo "Build Pipelines: $build_count"
    
    if [ "$build_count" -eq 0 ]; then
        echo "CRITICAL: No build pipelines configured!"
        echo "  - Code quality cannot be automatically validated"
        echo "  - No automated testing"
        echo "  - No deployment automation"
    else
        echo "Build Pipeline Details:"
        echo "$builds" | jq -r '.[] | "  - \(.name) (ID: \(.id))"' | head -3
        
        # Check recent build results
        first_build_id=$(echo "$builds" | jq -r '.[0].id')
        if recent_runs=$(az pipelines runs list --pipeline-id "$first_build_id" --top 5 --output json 2>/dev/null); then
            failed_runs=$(echo "$recent_runs" | jq '[.[] | select(.result == "failed")] | length')
            total_runs=$(echo "$recent_runs" | jq '. | length')
            
            echo "  Recent Build Results (last 5 runs):"
            echo "    Failed: $failed_runs/$total_runs"
            
            if [ "$failed_runs" -gt 2 ]; then
                echo "    WARNING: High failure rate may indicate code quality issues"
            fi
        fi
    fi
else
    echo "Cannot access build pipeline information"
fi

echo ""

# Repository health indicators
echo "6. REPOSITORY HEALTH INDICATORS"
echo "==============================="
if repo_stats=$(az repos stats show --repository "$AZURE_DEVOPS_REPO" --output json 2>/dev/null); then
    commits_count=$(echo "$repo_stats" | jq -r '.commitsCount // 0')
    pushes_count=$(echo "$repo_stats" | jq -r '.pushesCount // 0')
    
    echo "Repository Statistics:"
    echo "  Total Commits: $commits_count"
    echo "  Total Pushes: $pushes_count"
    
    if [ "$commits_count" -eq 0 ]; then
        echo "  CRITICAL: Repository has no commits!"
    elif [ "$commits_count" -lt 5 ]; then
        echo "  WARNING: Very few commits - repository may be new or inactive"
    fi
    
    if [ "$pushes_count" -gt 0 ] && [ "$commits_count" -gt 0 ]; then
        commits_per_push=$(echo "scale=1; $commits_count / $pushes_count" | bc -l 2>/dev/null || echo "1")
        echo "  Average Commits per Push: $commits_per_push"
        
        if (( $(echo "$commits_per_push < 1.2" | bc -l) )); then
            echo "  WARNING: Very frequent pushes may indicate workflow inefficiency"
        fi
    fi
else
    echo "Repository statistics not available"
fi

echo ""

# Security scan recommendations
echo "7. SECURITY RECOMMENDATIONS"
echo "==========================="
echo "Critical Security Actions Needed:"

# Check if default branch is protected
if [ "$enabled_policies" -eq 0 ]; then
    echo "  1. URGENT: Enable branch protection for default branch"
    echo "     - Require pull requests for changes"
    echo "     - Require at least 1 reviewer"
    echo "     - Require build validation"
fi

# Check for review requirements
reviewer_policies=$(echo "$branch_policies" | jq '[.[] | select(.type.displayName == "Minimum number of reviewers" and .isEnabled == true)] | length')
if [ "$reviewer_policies" -eq 0 ]; then
    echo "  2. URGENT: Configure required reviewers policy"
    echo "     - Minimum 1-2 reviewers required"
    echo "     - Dismiss stale reviews on new commits"
    echo "     - Prevent authors from approving their own changes"
fi

# Check for build validation
build_policies=$(echo "$branch_policies" | jq '[.[] | select(.type.displayName == "Build" and .isEnabled == true)] | length')
if [ "$build_policies" -eq 0 ]; then
    echo "  3. HIGH: Configure build validation policy"
    echo "     - Require successful build before merge"
    echo "     - Include automated tests"
    echo "     - Include security scans"
fi

echo ""

# Remediation steps
echo "8. IMMEDIATE REMEDIATION STEPS"
echo "=============================="
echo "Execute these steps to address critical issues:"
echo ""
echo "Step 1: Enable Branch Protection"
echo "  az repos policy create --policy-type minimum-reviewers \\"
echo "    --repository-id $repo_id \\"
echo "    --branch refs/heads/main \\"
echo "    --minimum-reviewers 1 \\"
echo "    --creator-vote-counts false"
echo ""
echo "Step 2: Add Build Validation (if build exists)"
if [ "$build_count" -gt 0 ]; then
    first_build_id=$(echo "$builds" | jq -r '.[0].id')
    echo "  az repos policy create --policy-type build \\"
    echo "    --repository-id $repo_id \\"
    echo "    --branch refs/heads/main \\"
    echo "    --build-definition-id $first_build_id"
fi
echo ""
echo "Step 3: Review and Clean Up Permissions"
echo "  - Audit repository permissions"
echo "  - Remove unnecessary access"
echo "  - Follow principle of least privilege"
echo ""
echo "Step 4: Implement Security Scanning"
echo "  - Add secret scanning to build pipeline"
echo "  - Implement dependency vulnerability scanning"
echo "  - Add code quality gates"

echo ""
echo "=== INVESTIGATION COMPLETE ==="
echo "Review the findings above and implement recommended security measures immediately."
echo "Critical issues require immediate attention to prevent security risks." 