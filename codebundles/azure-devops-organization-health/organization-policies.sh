#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AUTH_TYPE (optional, default: service_principal)
#   AZURE_DEVOPS_PAT (required if AUTH_TYPE=pat)
#
# This script:
#   1) Checks organization-level security policies
#   2) Verifies compliance settings
#   3) Reviews user access and permissions
#   4) Identifies security configuration issues
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AUTH_TYPE:=service_principal}"

OUTPUT_FILE="organization_policies.json"
policies_json='[]'

echo "Analyzing Organization Policies and Compliance..."
echo "Organization: $AZURE_DEVOPS_ORG"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" --output none

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
    echo "$AZURE_DEVOPS_PAT" | az devops login --organization "https://dev.azure.com/$AZURE_DEVOPS_ORG"
else
    echo "ERROR: Invalid AUTH_TYPE. Must be 'service_principal' or 'pat'"
    exit 1
fi

# Check organization security groups and permissions
echo "Checking organization security groups..."
if ! security_groups=$(az devops security group list --output json 2>security_err.log); then
    err_msg=$(cat security_err.log)
    rm -f security_err.log
    
    # This might be a permissions issue rather than a policy problem
    policies_json=$(echo "$policies_json" | jq \
        --arg title "Cannot Access Security Groups" \
        --arg details "Unable to access organization security groups: $err_msg" \
        --arg severity "2" \
        --arg next_steps "Verify that the service principal has permissions to read organization security settings" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
else
    group_count=$(echo "$security_groups" | jq '. | length')
    echo "Found $group_count security groups"
    
    # Check for common security groups
    admin_groups=$(echo "$security_groups" | jq '[.[] | select(.displayName | contains("Administrator"))] | length')
    contributor_groups=$(echo "$security_groups" | jq '[.[] | select(.displayName | contains("Contributor"))] | length')
    
    echo "  Administrator groups: $admin_groups"
    echo "  Contributor groups: $contributor_groups"
    
    if [ "$admin_groups" -eq 0 ]; then
        policies_json=$(echo "$policies_json" | jq \
            --arg title "No Administrator Groups Found" \
            --arg details "No administrator security groups found in organization" \
            --arg severity "3" \
            --arg next_steps "Verify that proper administrator groups exist and are configured" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi
rm -f security_err.log

# Check organization users and licensing
echo "Checking organization users..."
if ! users=$(az devops user list --output json 2>users_err.log); then
    err_msg=$(cat users_err.log)
    rm -f users_err.log
    
    policies_json=$(echo "$policies_json" | jq \
        --arg title "Cannot Access User Information" \
        --arg details "Unable to access organization users: $err_msg" \
        --arg severity "2" \
        --arg next_steps "Verify permissions to read user information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
else
    user_count=$(echo "$users" | jq '. | length')
    echo "Found $user_count users"
    
    # Analyze user access levels
    basic_users=$(echo "$users" | jq '[.[] | select(.accessLevel == "basic")] | length')
    stakeholder_users=$(echo "$users" | jq '[.[] | select(.accessLevel == "stakeholder")] | length')
    visual_studio_users=$(echo "$users" | jq '[.[] | select(.accessLevel == "visualStudioSubscriber")] | length')
    
    echo "  Basic users: $basic_users"
    echo "  Stakeholder users: $stakeholder_users"
    echo "  Visual Studio subscribers: $visual_studio_users"
    
    # Check for inactive users (this would require additional API calls to get last access time)
    # For now, we'll focus on access level distribution
    
    if [ "$user_count" -gt 100 ]; then
        policies_json=$(echo "$policies_json" | jq \
            --arg title "Large User Base" \
            --arg details "Organization has $user_count users - consider reviewing access management" \
            --arg severity "1" \
            --arg next_steps "Regularly review user access and remove inactive users to optimize licensing" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi
rm -f users_err.log

# Check project-level policies across all projects
echo "Checking project-level policies..."
if ! projects=$(az devops project list --output json 2>projects_err.log); then
    err_msg=$(cat projects_err.log)
    rm -f projects_err.log
    
    policies_json=$(echo "$policies_json" | jq \
        --arg title "Cannot Access Projects" \
        --arg details "Unable to access organization projects: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Verify permissions to read project information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
else
    project_count=$(echo "$projects" | jq '. | length')
    echo "Found $project_count projects"
    
    # Check project visibility settings
    public_projects=$(echo "$projects" | jq '[.[] | select(.visibility == "public")] | length')
    private_projects=$(echo "$projects" | jq '[.[] | select(.visibility == "private")] | length')
    
    echo "  Public projects: $public_projects"
    echo "  Private projects: $private_projects"
    
    if [ "$public_projects" -gt 0 ]; then
        policies_json=$(echo "$policies_json" | jq \
            --arg title "Public Projects Found" \
            --arg details "$public_projects projects are set to public visibility" \
            --arg severity "2" \
            --arg next_steps "Review public projects to ensure they should be publicly accessible" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    # Sample a few projects to check for repository policies
    projects_to_check=$(echo "$projects" | jq -r '.[0:3][].name')
    projects_without_policies=0
    
    for project in $projects_to_check; do
        echo "  Checking policies for project: $project"
        
        # Get repositories in this project
        if repos=$(az repos list --project "$project" --output json 2>/dev/null); then
            repo_count=$(echo "$repos" | jq '. | length')
            
            if [ "$repo_count" -gt 0 ]; then
                # Check first repository for branch policies
                first_repo_id=$(echo "$repos" | jq -r '.[0].id')
                
                if policies=$(az repos policy list --repository-id "$first_repo_id" --output json 2>/dev/null); then
                    policy_count=$(echo "$policies" | jq '. | length')
                    enabled_policies=$(echo "$policies" | jq '[.[] | select(.isEnabled == true)] | length')
                    
                    if [ "$enabled_policies" -eq 0 ]; then
                        projects_without_policies=$((projects_without_policies + 1))
                    fi
                    
                    echo "    Repository policies: $enabled_policies enabled out of $policy_count total"
                fi
            fi
        fi
    done
    
    if [ "$projects_without_policies" -gt 0 ]; then
        policies_json=$(echo "$policies_json" | jq \
            --arg title "Projects Without Branch Protection" \
            --arg details "$projects_without_policies out of sampled projects have no enabled branch protection policies" \
            --arg severity "2" \
            --arg next_steps "Review and implement branch protection policies across all projects" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi
rm -f projects_err.log

# Check service connections at organization level (sample across projects)
echo "Checking service connections security..."
service_connections_checked=0
insecure_connections=0

if [ "$project_count" -gt 0 ]; then
    # Check service connections in first few projects
    projects_to_check=$(echo "$projects" | jq -r '.[0:3][].name')
    
    for project in $projects_to_check; do
        echo "  Checking service connections in project: $project"
        
        if service_conns=$(az devops service-endpoint list --project "$project" --output json 2>/dev/null); then
            conn_count=$(echo "$service_conns" | jq '. | length')
            service_connections_checked=$((service_connections_checked + conn_count))
            
            # Check for connections without proper authorization
            unauth_conns=$(echo "$service_conns" | jq '[.[] | select(.authorization.scheme == null or .authorization.scheme == "")] | length')
            insecure_connections=$((insecure_connections + unauth_conns))
            
            echo "    Service connections: $conn_count total, $unauth_conns potentially insecure"
        fi
    done
    
    if [ "$insecure_connections" -gt 0 ]; then
        policies_json=$(echo "$policies_json" | jq \
            --arg title "Insecure Service Connections" \
            --arg details "$insecure_connections out of $service_connections_checked service connections may have security issues" \
            --arg severity "3" \
            --arg next_steps "Review service connection security settings and ensure proper authorization is configured" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Check for organization-level settings (this requires specific permissions)
echo "Checking organization settings..."
if ! org_settings=$(az devops configure --list 2>/dev/null); then
    echo "  Cannot access detailed organization settings (may require additional permissions)"
else
    echo "  Organization settings accessible"
fi

# If no policy issues found, add a healthy status
if [ "$(echo "$policies_json" | jq '. | length')" -eq 0 ]; then
    policies_json=$(echo "$policies_json" | jq \
        --arg title "Organization Policies: Compliant" \
        --arg details "Organization policies and security settings appear to be properly configured" \
        --arg severity "1" \
        --arg next_steps "Continue regular policy reviews and maintain current security standards" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$policies_json" > "$OUTPUT_FILE"
echo "Organization policies analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== ORGANIZATION POLICIES SUMMARY ==="
echo "$policies_json" | jq -r '.[] | "Policy: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 