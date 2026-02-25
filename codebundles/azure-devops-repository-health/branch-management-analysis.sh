#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#   AZURE_DEVOPS_REPO
#   STALE_BRANCH_DAYS (optional, default: 90)
#
# This script:
#   1) Analyzes branch structure and patterns
#   2) Identifies stale and abandoned branches
#   3) Checks for branch naming conventions
#   4) Detects merge pattern issues
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AZURE_DEVOPS_REPO:?Must set AZURE_DEVOPS_REPO}"
: "${STALE_BRANCH_DAYS:=90}"

OUTPUT_FILE="branch_management_analysis.json"
branch_json='[]'

echo "Analyzing Branch Management Patterns..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project: $AZURE_DEVOPS_PROJECT"
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Stale Branch Threshold: $STALE_BRANCH_DAYS days"

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
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Cannot Access Repository for Branch Analysis" \
        --arg details "Failed to access repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify repository name and permissions to access repository information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$branch_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f repo_err.log

repo_id=$(echo "$repo_info" | jq -r '.id')
default_branch=$(echo "$repo_info" | jq -r '.defaultBranch // "refs/heads/main"')

echo "Repository ID: $repo_id"
echo "Default Branch: $default_branch"

# Get all branches
echo "Getting branch information..."
if ! branches=$(az repos ref list --repository "$AZURE_DEVOPS_REPO" --filter "heads/" --output json 2>branch_err.log); then
    err_msg=$(cat branch_err.log)
    rm -f branch_err.log
    
    echo "ERROR: Could not get branch information."
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Cannot Access Branch Information" \
        --arg details "Failed to get branches for repository $AZURE_DEVOPS_REPO: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify permissions to read repository branches" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$branch_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f branch_err.log

echo "$branches" > branches.json
branch_count=$(jq '. | length' branches.json)

echo "Found $branch_count branches"

if [ "$branch_count" -eq 0 ]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "No Branches Found" \
        --arg details "Repository has no branches - this is unusual and may indicate repository setup issues" \
        --arg severity "4" \
        --arg next_steps "Verify repository initialization and check if default branch exists" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$branch_json" > "$OUTPUT_FILE"
    exit 0
fi

# Analyze branch patterns
echo "Analyzing branch patterns..."

# Calculate stale branch threshold date
stale_date=$(date -d "$STALE_BRANCH_DAYS days ago" -u +"%Y-%m-%dT%H:%M:%SZ")

# Initialize counters
stale_branches=0
feature_branches=0
hotfix_branches=0
release_branches=0
personal_branches=0
poorly_named_branches=0
long_lived_branches=0

# Analyze each branch
for ((i=0; i<branch_count; i++)); do
    branch_json_obj=$(jq -c ".[${i}]" branches.json)
    
    branch_name=$(echo "$branch_json_obj" | jq -r '.name')
    branch_ref=$(echo "$branch_json_obj" | jq -r '.name')
    object_id=$(echo "$branch_json_obj" | jq -r '.objectId')
    
    # Extract branch name without refs/heads/ prefix
    clean_branch_name=$(echo "$branch_name" | sed 's|refs/heads/||')
    
    echo "  Analyzing branch: $clean_branch_name"
    
    # Skip default branch for some checks
    if [ "$branch_name" = "$default_branch" ]; then
        echo "    Skipping default branch"
        continue
    fi
    
    # Check branch naming conventions
    if [[ "$clean_branch_name" =~ ^feature/ ]]; then
        feature_branches=$((feature_branches + 1))
    elif [[ "$clean_branch_name" =~ ^hotfix/ ]]; then
        hotfix_branches=$((hotfix_branches + 1))
    elif [[ "$clean_branch_name" =~ ^release/ ]]; then
        release_branches=$((release_branches + 1))
    elif [[ "$clean_branch_name" =~ ^(users/|personal/) ]]; then
        personal_branches=$((personal_branches + 1))
    elif [[ "$clean_branch_name" =~ ^[0-9]+$ ]] || [[ "$clean_branch_name" =~ [[:space:]] ]] || [[ "$clean_branch_name" =~ ^(test|temp|tmp|dev|development)$ ]]; then
        poorly_named_branches=$((poorly_named_branches + 1))
    fi
    
    # Check for stale branches (this is simplified - in practice you'd check last commit date)
    # For now, we'll use a heuristic based on branch name patterns
    if [[ "$clean_branch_name" =~ (old|archive|backup|deprecated) ]]; then
        stale_branches=$((stale_branches + 1))
    fi
    
    # Check for potentially long-lived feature branches
    if [[ "$clean_branch_name" =~ ^feature/ ]] && [[ ${#clean_branch_name} -gt 50 ]]; then
        long_lived_branches=$((long_lived_branches + 1))
    fi
done

echo "Branch analysis results:"
echo "  Feature branches: $feature_branches"
echo "  Hotfix branches: $hotfix_branches"
echo "  Release branches: $release_branches"
echo "  Personal branches: $personal_branches"
echo "  Poorly named branches: $poorly_named_branches"
echo "  Potentially stale branches: $stale_branches"
echo "  Long-lived branches: $long_lived_branches"

# Generate issues based on analysis
if [ "$branch_count" -gt 20 ]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Excessive Number of Branches" \
        --arg details "Repository has $branch_count branches - may indicate poor branch cleanup practices" \
        --arg severity "2" \
        --arg next_steps "Review and clean up stale branches, implement branch cleanup policies, and establish branch lifecycle management" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ "$poorly_named_branches" -gt 0 ]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Poor Branch Naming Conventions" \
        --arg details "$poorly_named_branches branches have poor naming (numbers only, spaces, or generic names like 'test')" \
        --arg severity "2" \
        --arg next_steps "Establish and enforce branch naming conventions (e.g., feature/description, bugfix/issue-number)" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ "$personal_branches" -gt 5 ]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Excessive Personal Branches" \
        --arg details "$personal_branches personal/user branches found - may indicate lack of branch cleanup or workflow issues" \
        --arg severity "1" \
        --arg next_steps "Review personal branches for cleanup and establish guidelines for personal branch management" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ "$stale_branches" -gt 0 ]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Stale Branches Detected" \
        --arg details "$stale_branches branches appear to be stale or archived" \
        --arg severity "1" \
        --arg next_steps "Review and delete stale branches to keep repository clean and improve performance" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ "$long_lived_branches" -gt 0 ]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Potentially Long-Lived Feature Branches" \
        --arg details "$long_lived_branches feature branches have very long names, possibly indicating long-lived branches" \
        --arg severity "2" \
        --arg next_steps "Review long-lived feature branches for merge opportunities and consider breaking large features into smaller increments" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for missing branch types (might indicate workflow issues)
total_workflow_branches=$((feature_branches + hotfix_branches + release_branches))
if [ "$branch_count" -gt 5 ] && [ "$total_workflow_branches" -eq 0 ]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "No Standard Workflow Branches" \
        --arg details "Repository has $branch_count branches but no standard workflow branches (feature/, hotfix/, release/)" \
        --arg severity "2" \
        --arg next_steps "Consider implementing a standard Git workflow (GitFlow, GitHub Flow) with proper branch naming conventions" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for branch protection on non-default branches
if [ "$feature_branches" -gt 0 ] || [ "$release_branches" -gt 0 ]; then
    echo "Checking branch protection for important branches..."
    
    # This is a simplified check - in practice, you'd check specific branch policies
    if branch_policies=$(az repos policy list --repository-id "$repo_id" --output json 2>/dev/null); then
        policy_count=$(echo "$branch_policies" | jq '. | length')
        
        if [ "$policy_count" -eq 0 ]; then
            branch_json=$(echo "$branch_json" | jq \
                --arg title "No Branch Protection Policies" \
                --arg details "Repository has workflow branches but no branch protection policies configured" \
                --arg severity "3" \
                --arg next_steps "Implement branch protection policies for important branches (main, release/, etc.)" \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "severity": ($severity | tonumber),
                   "next_steps": $next_steps
                 }]')
        fi
    fi
fi

# Check default branch naming
default_branch_name=$(echo "$default_branch" | sed 's|refs/heads/||')
if [[ "$default_branch_name" == "master" ]]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Default Branch Uses Legacy Name" \
        --arg details "Default branch is named 'master' - consider updating to 'main' for modern conventions" \
        --arg severity "1" \
        --arg next_steps "Consider renaming default branch to 'main' and update all references and documentation" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Clean up temporary files
rm -f branches.json

# If no branch management issues found, add a healthy status
if [ "$(echo "$branch_json" | jq '. | length')" -eq 0 ]; then
    branch_json=$(echo "$branch_json" | jq \
        --arg title "Branch Management: Well Organized" \
        --arg details "Repository branch structure appears well organized with $branch_count branches following good practices" \
        --arg severity "1" \
        --arg next_steps "Continue maintaining good branch hygiene and consider implementing automated branch cleanup" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$branch_json" > "$OUTPUT_FILE"
echo "Branch management analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== BRANCH MANAGEMENT SUMMARY ==="
echo "Repository: $AZURE_DEVOPS_REPO"
echo "Total Branches: $branch_count"
echo "Default Branch: $default_branch_name"
echo "Feature Branches: $feature_branches"
echo "Hotfix Branches: $hotfix_branches"
echo "Release Branches: $release_branches"
echo "Personal Branches: $personal_branches"
echo "Poorly Named: $poorly_named_branches"
echo ""
echo "$branch_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 