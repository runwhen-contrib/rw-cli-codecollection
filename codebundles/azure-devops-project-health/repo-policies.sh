#!/usr/bin/env bash
# set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG - Azure DevOps organization name
#   AZURE_DEVOPS_PROJECT - Azure DevOps project name (optional, checks all projects if not specified)
#
# This script:
#   1) Lists all repositories in the specified Azure DevOps organization/project
#   2) Checks branch policies against the standards defined in policy-standards.json
#   3) Identifies missing or misconfigured policies
#   4) Outputs results in JSON format with clustered issues by type
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AUTH_TYPE:=service_principal}"

OUTPUT_FILE="repo_policies_issues.json"
issues_json='[]'
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"

# Clustered issue tracking
missing_reviewers_repos=()
missing_build_validation_repos=()
missing_work_item_linking_repos=()
naming_convention_repos=()
unlocked_branches_repos=()
missing_pr_requirement_repos=()
insufficient_reviewers_repos=()
access_denied_repos=()

echo "Analyzing Azure DevOps Repository Policies..."
echo "Organization: $AZURE_DEVOPS_ORG"
if [[ -n "$AZURE_DEVOPS_PROJECT" ]]; then
    echo "Project: $AZURE_DEVOPS_PROJECT"
fi

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="$ORG_URL" --output none

# Setup authentication
if [ "$AUTH_TYPE" = "service_principal" ]; then
    echo "Using service principal authentication..."
    # Service principal authentication is handled by Azure CLI login
elif [ "$AUTH_TYPE" = "pat" ]; then
    if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
        echo "ERROR: AZURE_DEVOPS_PAT must be set when AUTH_TYPE=pat"
        exit 1
    fi
    echo "Using PAT authentication..."
    echo "$AZURE_DEVOPS_PAT" | az devops login --organization "$ORG_URL"
else
    echo "ERROR: Invalid AUTH_TYPE. Must be 'service_principal' or 'pat'"
    exit 1
fi

# Load policy standards
if [[ -f "policy-standards.json" ]]; then
    policy_standards=$(cat policy-standards.json)
    echo "Loaded policy standards from policy-standards.json"
else
    echo "WARNING: policy-standards.json not found. Using default standards."
    # Default minimal standards if file not found
    policy_standards='{
      "requiredPolicies": {
        "minimumReviewers": {
          "typeId": "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd",
          "displayName": "Minimum number of reviewers",
          "settings": {
            "minimumApproverCount": 2,
            "creatorVoteCounts": false,
            "allowDownvotes": false,
            "resetOnSourcePush": true
          }
        },
        "workItemLinking": {
          "typeId": "40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e",
          "displayName": "Work item linking",
          "settings": {
            "enabled": true,
            "workItemType": "Any"
          }
        }
      },
      "branchPolicies": {
        "defaultBranch": {
          "isLocked": true,
          "requirePullRequest": true,
          "resetOnSourcePush": true
        }
      }
    }'
fi

# Get list of projects
if [[ -n "$AZURE_DEVOPS_PROJECT" ]]; then
    projects_json="[{\"name\": \"$AZURE_DEVOPS_PROJECT\"}]"
else
    echo "Retrieving all projects in organization..."
    if ! projects_json=$(az devops project list --org "$ORG_URL" --output json 2>projects_err.log); then
        err_msg=$(cat projects_err.log)
        rm -f projects_err.log
        
        echo "ERROR: Could not list projects."
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to List Projects in Organization \`${AZURE_DEVOPS_ORG}\`" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Check if you have sufficient permissions to view projects." \
            '. += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber)
            }]')
        echo "$issues_json" > "$OUTPUT_FILE"
        exit 1
    fi
    projects_json=$(echo "$projects_json" | jq '.value')
    rm -f projects_err.log
fi

# Save projects to a file to avoid subshell issues
echo "$projects_json" > projects.json

# Get the number of projects
project_count=$(jq '. | length' projects.json)
echo "Found $project_count project(s) to analyze"

# Process each project
for ((p=0; p<project_count; p++)); do
    project_name=$(jq -r ".[$p].name" projects.json)
    echo "Processing Project: $project_name"
    
    # Get repositories in the project
    if ! repos_json=$(az repos list --project "$project_name" --org "$ORG_URL" --output json 2>repos_err.log); then
        err_msg=$(cat repos_err.log)
        rm -f repos_err.log
        
        access_denied_repos+=("$project_name")
        continue
    fi
    rm -f repos_err.log
    
    # Save repos to a file to avoid subshell issues
    echo "$repos_json" > repos.json
    
    # Get the number of repos
    repo_count=$(jq '. | length' repos.json)
    echo "Found $repo_count repositories in project $project_name"
    
    # Process each repository
    for ((r=0; r<repo_count; r++)); do
        repo_json=$(jq ".[$r]" repos.json)
        repo_id=$(echo "$repo_json" | jq -r '.id')
        repo_name=$(echo "$repo_json" | jq -r '.name')
        repo_default_branch=$(echo "$repo_json" | jq -r '.defaultBranch')
        
        # If default branch is null or empty, skip this repo
        if [[ "$repo_default_branch" == "null" || -z "$repo_default_branch" ]]; then
            echo "  Skipping repository $repo_name - no default branch found"
            continue
        fi
        
        # Remove 'refs/heads/' prefix from branch name
        repo_default_branch=${repo_default_branch#refs/heads/}
        
        echo "  Processing Repository: $repo_name (Default Branch: $repo_default_branch)"
        
        # Check repository name against naming convention
        repo_naming_pattern=$(echo "$policy_standards" | jq -r '.namingConventions.repositories')
        if [[ -n "$repo_naming_pattern" && "$repo_naming_pattern" != "null" ]]; then
            if ! [[ "$repo_name" =~ $repo_naming_pattern ]]; then
                naming_convention_repos+=("$project_name/$repo_name")
            fi
        fi
        
        # Get branch policies for the default branch
        default_branch_id="refs/heads/$repo_default_branch"
        if ! policies_json=$(az repos policy list --repository-id "$repo_id" --branch "$default_branch_id" --project "$project_name" --org "$ORG_URL" --output json 2>policies_err.log); then
            err_msg=$(cat policies_err.log)
            rm -f policies_err.log
            
            access_denied_repos+=("$project_name/$repo_name")
            continue
        fi
        rm -f policies_err.log
        
        # Check if default branch is locked
        if [[ $(echo "$policy_standards" | jq -r '.branchPolicies.defaultBranch.isLocked') == "true" ]]; then
            # Check if branch has lock policy
            if ! echo "$policies_json" | jq -e '[.[] | select(.type.id == "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab")] | length > 0' > /dev/null; then
                unlocked_branches_repos+=("$project_name/$repo_name ($repo_default_branch)")
            fi
        fi
        
        # Check if default branch requires pull request
        if [[ $(echo "$policy_standards" | jq -r '.branchPolicies.defaultBranch.requirePullRequest') == "true" ]]; then
            # Check if branch has PR policy
            if ! echo "$policies_json" | jq -e '[.[] | select(.type.id == "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd")] | length > 0' > /dev/null; then
                missing_pr_requirement_repos+=("$project_name/$repo_name ($repo_default_branch)")
            fi
        fi
        
        # Check for required policies
        required_policies=$(echo "$policy_standards" | jq -r '.requiredPolicies | keys[]')
        for policy_key in $required_policies; do
            policy_type_id=$(echo "$policy_standards" | jq -r ".requiredPolicies.$policy_key.typeId")
            policy_display_name=$(echo "$policy_standards" | jq -r ".requiredPolicies.$policy_key.displayName")
            
            # Check if policy exists
            if ! echo "$policies_json" | jq -e --arg type_id "$policy_type_id" '[.[] | select(.type.id == $type_id)] | length > 0' > /dev/null; then
                case "$policy_key" in
                    "minimumReviewers")
                        missing_reviewers_repos+=("$project_name/$repo_name")
                        ;;
                    "buildValidation")
                        missing_build_validation_repos+=("$project_name/$repo_name")
                        ;;
                    "workItemLinking")
                        missing_work_item_linking_repos+=("$project_name/$repo_name")
                        ;;
                esac
            else
                # Policy exists, check settings
                policy_settings=$(echo "$policy_standards" | jq -r ".requiredPolicies.$policy_key.settings")
                actual_policy=$(echo "$policies_json" | jq --arg type_id "$policy_type_id" '[.[] | select(.type.id == $type_id)][0]')
                
                # For minimum reviewers policy, check the count
                if [[ "$policy_key" == "minimumReviewers" ]]; then
                    required_count=$(echo "$policy_settings" | jq -r '.minimumApproverCount')
                    actual_count=$(echo "$actual_policy" | jq -r '.settings.minimumApproverCount')
                    
                    if [[ "$actual_count" -lt "$required_count" ]]; then
                        insufficient_reviewers_repos+=("$project_name/$repo_name (has $actual_count, needs $required_count)")
                    fi
                fi
            fi
        done
    done
    
    # Clean up repos file
    rm -f repos.json
done

# Clean up projects file
rm -f projects.json

# Generate clustered issues
if [ ${#access_denied_repos[@]} -gt 0 ]; then
    repo_list=$(printf '%s\n' "${access_denied_repos[@]}" | head -10)
    if [ ${#access_denied_repos[@]} -gt 10 ]; then
        repo_list="${repo_list}... and $((${#access_denied_repos[@]} - 10)) more"
    fi
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot Access Repository Policies in ${#access_denied_repos[@]} Repository/Project(s)" \
        --arg details "Failed to access repository policies for:\n$repo_list" \
        --arg severity "3" \
        --arg nextStep "Check if you have sufficient permissions to view repository policies in these projects." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
fi

if [ ${#missing_reviewers_repos[@]} -gt 0 ]; then
    repo_list=$(printf '%s\n' "${missing_reviewers_repos[@]}" | head -10)
    if [ ${#missing_reviewers_repos[@]} -gt 10 ]; then
        repo_list="${repo_list}... and $((${#missing_reviewers_repos[@]} - 10)) more"
    fi
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Required Reviewers Policy in ${#missing_reviewers_repos[@]} Repository/ies" \
        --arg details "The following repositories lack required reviewers policy (best practice):\n$repo_list" \
        --arg severity "4" \
        --arg nextStep "Consider adding minimum reviewers policy to these repositories for better code review coverage." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
fi

if [ ${#missing_build_validation_repos[@]} -gt 0 ]; then
    repo_list=$(printf '%s\n' "${missing_build_validation_repos[@]}" | head -10)
    if [ ${#missing_build_validation_repos[@]} -gt 10 ]; then
        repo_list="${repo_list}... and $((${#missing_build_validation_repos[@]} - 10)) more"
    fi
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Build Validation Policy in ${#missing_build_validation_repos[@]} Repository/ies" \
        --arg details "The following repositories lack build validation policy (best practice):\n$repo_list" \
        --arg severity "4" \
        --arg nextStep "Consider adding build validation policy to ensure code passes tests before merge." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
fi

if [ ${#missing_work_item_linking_repos[@]} -gt 0 ]; then
    repo_list=$(printf '%s\n' "${missing_work_item_linking_repos[@]}" | head -10)
    if [ ${#missing_work_item_linking_repos[@]} -gt 10 ]; then
        repo_list="${repo_list}... and $((${#missing_work_item_linking_repos[@]} - 10)) more"
    fi
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Work Item Linking Policy in ${#missing_work_item_linking_repos[@]} Repository/ies" \
        --arg details "The following repositories lack work item linking policy (best practice):\n$repo_list" \
        --arg severity "4" \
        --arg nextStep "Consider adding work item linking policy to improve traceability between code changes and work items." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
fi

if [ ${#naming_convention_repos[@]} -gt 0 ]; then
    repo_list=$(printf '%s\n' "${naming_convention_repos[@]}" | head -10)
    if [ ${#naming_convention_repos[@]} -gt 10 ]; then
        repo_list="${repo_list}... and $((${#naming_convention_repos[@]} - 10)) more"
    fi
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Repository Naming Convention Violations in ${#naming_convention_repos[@]} Repository/ies" \
        --arg details "The following repositories do not follow naming conventions (best practice):\n$repo_list" \
        --arg severity "4" \
        --arg nextStep "Consider renaming repositories to follow the established naming convention." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
fi

# These are enforced policies, keep higher severity
if [ ${#unlocked_branches_repos[@]} -gt 0 ]; then
    repo_list=$(printf '%s\n' "${unlocked_branches_repos[@]}" | head -10)
    if [ ${#unlocked_branches_repos[@]} -gt 10 ]; then
        repo_list="${repo_list}... and $((${#unlocked_branches_repos[@]} - 10)) more"
    fi
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Default Branches Not Locked in ${#unlocked_branches_repos[@]} Repository/ies" \
        --arg details "The following repositories have unlocked default branches (policy violation):\n$repo_list" \
        --arg severity "3" \
        --arg nextStep "Enable branch lock policy for default branches to prevent direct pushes." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
fi

if [ ${#missing_pr_requirement_repos[@]} -gt 0 ]; then
    repo_list=$(printf '%s\n' "${missing_pr_requirement_repos[@]}" | head -10)
    if [ ${#missing_pr_requirement_repos[@]} -gt 10 ]; then
        repo_list="${repo_list}... and $((${#missing_pr_requirement_repos[@]} - 10)) more"
    fi
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Pull Request Requirement Missing in ${#missing_pr_requirement_repos[@]} Repository/ies" \
        --arg details "The following repositories do not require pull requests for default branch (policy violation):\n$repo_list" \
        --arg severity "3" \
        --arg nextStep "Enable pull request requirement for default branches to enforce code review process." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
fi

if [ ${#insufficient_reviewers_repos[@]} -gt 0 ]; then
    repo_list=$(printf '%s\n' "${insufficient_reviewers_repos[@]}" | head -10)
    if [ ${#insufficient_reviewers_repos[@]} -gt 10 ]; then
        repo_list="${repo_list}... and $((${#insufficient_reviewers_repos[@]} - 10)) more"
    fi
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Insufficient Required Reviewers in ${#insufficient_reviewers_repos[@]} Repository/ies" \
        --arg details "The following repositories have insufficient reviewer requirements:\n$repo_list" \
        --arg severity "2" \
        --arg nextStep "Increase the minimum number of required reviewers to meet policy standards." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
fi

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps repository policy analysis completed. Saved results to $OUTPUT_FILE"