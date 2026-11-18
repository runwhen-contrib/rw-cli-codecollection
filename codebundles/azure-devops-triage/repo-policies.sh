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
#   4) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"

OUTPUT_FILE="repo_policies_issues.json"
issues_json='[]'
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"

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
            --arg title "Failed to List Projects" \
            --arg details "$err_msg" \
            --arg severity "4" \
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
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to List Repositories in Project \`$project_name\`" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Check if you have sufficient permissions to view repositories in this project." \
            '. += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber)
             }]')
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
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Repository Name Does Not Match Convention" \
                    --arg details "Repository \`$repo_name\` in project \`$project_name\` does not match the naming convention pattern: $repo_naming_pattern" \
                    --arg severity "2" \
                    --arg nextStep "Consider renaming the repository to follow the naming convention." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber)
                     }]')
            fi
        fi
        
        # Get branch policies for the default branch
        default_branch_id="refs/heads/$repo_default_branch"
        if ! policies_json=$(az repos policy list --repository-id "$repo_id" --branch "$default_branch_id" --project "$project_name" --org "$ORG_URL" --output json 2>policies_err.log); then
            err_msg=$(cat policies_err.log)
            rm -f policies_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed to List Policies for Repository \`$repo_name\`" \
                --arg details "$err_msg" \
                --arg severity "3" \
                --arg nextStep "Check if you have sufficient permissions to view policies in this repository." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
            continue
        fi
        rm -f policies_err.log
        
        # Check if default branch is locked
        if [[ $(echo "$policy_standards" | jq -r '.branchPolicies.defaultBranch.isLocked') == "true" ]]; then
            # Check if branch has lock policy
            if ! echo "$policies_json" | jq -e '[.[] | select(.type.id == "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab")] | length > 0' > /dev/null; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Default Branch Not Locked" \
                    --arg details "Default branch \`$repo_default_branch\` in repository \`$repo_name\` (project \`$project_name\`) is not locked as required by policy." \
                    --arg severity "3" \
                    --arg nextStep "Enable branch lock policy for the default branch." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber)
                     }]')
            fi
        fi
        
        # Check if default branch requires pull request
        if [[ $(echo "$policy_standards" | jq -r '.branchPolicies.defaultBranch.requirePullRequest') == "true" ]]; then
            # Check if branch has PR policy
            if ! echo "$policies_json" | jq -e '[.[] | select(.type.id == "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd")] | length > 0' > /dev/null; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Default Branch Does Not Require Pull Requests" \
                    --arg details "Default branch \`$repo_default_branch\` in repository \`$repo_name\` (project \`$project_name\`) does not require pull requests as required by policy." \
                    --arg severity "3" \
                    --arg nextStep "Enable pull request policy for the default branch." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber)
                     }]')
            fi
        fi
        
        # Check for required policies
        required_policies=$(echo "$policy_standards" | jq -r '.requiredPolicies | keys[]')
        for policy_key in $required_policies; do
            policy_type_id=$(echo "$policy_standards" | jq -r ".requiredPolicies.$policy_key.typeId")
            policy_display_name=$(echo "$policy_standards" | jq -r ".requiredPolicies.$policy_key.displayName")
            
            # Check if policy exists
            if ! echo "$policies_json" | jq -e --arg type_id "$policy_type_id" '[.[] | select(.type.id == $type_id)] | length > 0' > /dev/null; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Missing Required Policy: $policy_display_name" \
                    --arg details "Repository \`$repo_name\` (project \`$project_name\`) is missing the required policy: $policy_display_name" \
                    --arg severity "3" \
                    --arg nextStep "Add the required policy to the repository's default branch." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber)
                     }]')
            else
                # Policy exists, check settings
                policy_settings=$(echo "$policy_standards" | jq -r ".requiredPolicies.$policy_key.settings")
                actual_policy=$(echo "$policies_json" | jq --arg type_id "$policy_type_id" '[.[] | select(.type.id == $type_id)][0]')
                
                # For minimum reviewers policy, check the count
                if [[ "$policy_key" == "minimumReviewers" ]]; then
                    required_count=$(echo "$policy_settings" | jq -r '.minimumApproverCount')
                    actual_count=$(echo "$actual_policy" | jq -r '.settings.minimumApproverCount')
                    
                    if [[ "$actual_count" -lt "$required_count" ]]; then
                        issues_json=$(echo "$issues_json" | jq \
                            --arg title "Insufficient Minimum Reviewers" \
                            --arg details "Repository \`$repo_name\` (project \`$project_name\`) requires only $actual_count reviewers, but policy requires $required_count." \
                            --arg severity "2" \
                            --arg nextStep "Increase the minimum number of required reviewers to $required_count." \
                            '. += [{
                               "title": $title,
                               "details": $details,
                               "next_step": $nextStep,
                               "severity": ($severity | tonumber)
                             }]')
                    fi
                fi
                
                # For build validation, check if it's configured
                if [[ "$policy_key" == "buildValidation" ]]; then
                    if echo "$actual_policy" | jq -e '.settings.buildDefinitionId == 0' > /dev/null; then
                        issues_json=$(echo "$issues_json" | jq \
                            --arg title "Build Validation Not Configured" \
                            --arg details "Repository \`$repo_name\` (project \`$project_name\`) has build validation policy but no build definition is selected." \
                            --arg severity "2" \
                            --arg nextStep "Configure a build definition for the build validation policy." \
                            '. += [{
                               "title": $title,
                               "details": $details,
                               "next_step": $nextStep,
                               "severity": ($severity | tonumber)
                             }]')
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

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps repository policy analysis completed. Saved results to $OUTPUT_FILE"