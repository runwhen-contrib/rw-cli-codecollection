#!/usr/bin/env bash
set -euo pipefail
# NOTE: `set -x` is intentionally NOT used (it leaks AZURE_DEVOPS_PAT into logs).
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AUTH_TYPE (optional, default: service_principal)
#   AZURE_DEVOPS_PAT (required if AUTH_TYPE=pat)
#
# This script:
#   1) Checks organization-level security policies
#   2) Verifies compliance settings
#   3) Reviews user access and permissions (ALL users, paginated)
#   4) Identifies security configuration issues with clustered reporting
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="organization_policies.json"
policies_json='[]'

# Clustered issue tracking
public_projects=()
projects_without_policies=()
insecure_service_connections=()
access_denied_areas=()

echo "Analyzing Organization Policies and Compliance..."
echo "Organization: $AZURE_DEVOPS_ORG"

setup_azure_auth

# Check organization security groups and permissions
echo "Checking organization security groups..."
if ! security_groups=$(az devops security group list --output json 2>security_err.log); then
    err_msg=$(cat security_err.log)
    rm -f security_err.log
    
    access_denied_areas+=("Security Groups: $err_msg")
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
            --arg title "No Administrator Groups Found in Organization \`${AZURE_DEVOPS_ORG}\`" \
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

# Check organization users and licensing (paginated to include ALL users)
echo "Checking organization users..."
if ! users=$(get_all_users); then
    access_denied_areas+=("User Information: Member Entitlement Management API unavailable (requires the 'Member Entitlement Management (Read)' PAT scope and Project Collection Administrator rights).")
else
    user_count=$(echo "$users" | jq '.items | length')
    echo "Found $user_count users"
    if [ "$(echo "$users" | jq -r '.partial // false')" = "true" ]; then
        echo "WARNING: user list is incomplete (pagination stopped early); user-based policy findings are based on a partial set."
        access_denied_areas+=("User Information: pagination incomplete - analyzed only $user_count users (a page failed or the safety cap was reached); user-based policy findings may be understated.")
    fi
    
    # Analyze user access levels. Keep this categorisation consistent with
    # license-utilization.sh: express/professional -> Basic, advanced -> Basic +
    # Test Plans, stakeholder -> free, and Visual Studio subscribers are detected
    # via msdnLicenseType / licensingSource (not a distinct accountLicenseType).
    license_counts=$(echo "$users" | jq -c '
        def lvl:    (.accessLevel.accountLicenseType // "none");
        def msdn:   (.accessLevel.msdnLicenseType   // "none");
        def licsrc: (.accessLevel.licensingSource    // "none");
        def is_vs:  ((msdn != "none") or (licsrc == "msdn"));
        reduce .items[] as $x ({basic:0, advanced:0, stakeholder:0, vs:0, other:0};
            ($x | is_vs) as $v | ($x | lvl) as $l |
            if   $l == "stakeholder"                       then .stakeholder += 1
            elif $v                                        then .vs += 1
            elif ($l == "express" or $l == "professional") then .basic += 1
            elif $l == "advanced"                          then .advanced += 1
            else .other += 1 end)')
    basic_users=$(echo "$license_counts" | jq -r '.basic')
    advanced_users=$(echo "$license_counts" | jq -r '.advanced')
    stakeholder_users=$(echo "$license_counts" | jq -r '.stakeholder')
    visual_studio_users=$(echo "$license_counts" | jq -r '.vs')
    
    echo "  Basic users (express/professional): $basic_users"
    echo "  Basic + Test Plans (advanced): $advanced_users"
    echo "  Stakeholder users: $stakeholder_users"
    echo "  Visual Studio subscribers: $visual_studio_users"
    
    # Check for inactive users (this would require additional API calls to get last access time)
    # For now, we'll focus on access level distribution
    
    if [ "$user_count" -gt 100 ]; then
        policies_json=$(echo "$policies_json" | jq \
            --arg title "Large User Base in Organization \`${AZURE_DEVOPS_ORG}\`" \
            --arg details "Organization has $user_count users - consider reviewing access management" \
            --arg severity "4" \
            --arg next_steps "Regularly review user access and remove inactive users to optimize licensing" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Check project-level policies across all projects
echo "Checking project-level policies..."
project_count=0
projects='{"value":[]}'
if ! projects=$(az devops project list --output json 2>projects_err.log); then
    err_msg=$(cat projects_err.log)
    rm -f projects_err.log
    
    access_denied_areas+=("Projects: $err_msg")
else
    project_count=$(echo "$projects" | jq '.value | length')
    echo "Found $project_count projects"
    
    # Check project visibility settings
    public_project_names=$(echo "$projects" | jq -r '.value[] | select(.visibility == "public") | .name')
    private_projects=$(echo "$projects" | jq '[.value[] | select(.visibility == "private")] | length')
    
    echo "  Public projects: $(echo "$public_project_names" | wc -l | tr -d ' ')"
    echo "  Private projects: $private_projects"
    
    # Store public project names for clustering
    while IFS= read -r project_name; do
        if [[ -n "$project_name" ]]; then
            public_projects+=("$project_name")
        fi
    done <<< "$public_project_names"
    
    # Sample a few projects to check for repository policies
    projects_to_check=$(echo "$projects" | jq -r '.value[0:3][].name')
    
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
                        projects_without_policies+=("$project")
                    fi
                    
                    echo "    Repository policies: $enabled_policies enabled out of $policy_count total"
                fi
            fi
        fi
    done
fi
rm -f projects_err.log

# Check service connections at organization level (sample across projects)
echo "Checking service connections security..."
service_connections_checked=0

if [ "$project_count" -gt 0 ]; then
    # Check service connections in first few projects
    projects_to_check=$(echo "$projects" | jq -r '.value[0:3][].name')
    
    for project in $projects_to_check; do
        echo "  Checking service connections in project: $project"
        
        if service_conns=$(az devops service-endpoint list --project "$project" --output json 2>/dev/null); then
            conn_count=$(echo "$service_conns" | jq '. | length')
            service_connections_checked=$((service_connections_checked + conn_count))
            
            # Check for connections without proper authorization
            unauth_conn_names=$(echo "$service_conns" | jq -r '.[] | select(.authorization.scheme == null or .authorization.scheme == "") | "\(.name) (\(.type))"')
            
            while IFS= read -r conn_name; do
                if [[ -n "$conn_name" ]]; then
                    insecure_service_connections+=("$project/$conn_name")
                fi
            done <<< "$unauth_conn_names"
            
            echo "    Service connections: $conn_count total"
        fi
    done
fi

# Check for organization-level settings (this requires specific permissions)
echo "Checking organization settings..."
if ! org_settings=$(az devops configure --list 2>/dev/null); then
    echo "  Cannot access detailed organization settings (may require additional permissions)"
    access_denied_areas+=("Organization Settings: Limited permissions")
else
    echo "  Organization settings accessible"
fi

# Generate clustered issues
if [ ${#access_denied_areas[@]} -gt 0 ]; then
    area_list=$(printf '%s\n' "${access_denied_areas[@]}")
    
    policies_json=$(echo "$policies_json" | jq \
        --arg title "Limited Access to Organization Security Areas in \`${AZURE_DEVOPS_ORG}\`" \
        --arg details "Cannot access the following security areas (may require elevated permissions):\n$area_list" \
        --arg severity "2" \
        --arg next_steps "Verify that the service principal has permissions to read organization security settings" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#public_projects[@]} -gt 0 ]; then
    project_list=$(printf '%s\n' "${public_projects[@]}" | head -10)
    if [ ${#public_projects[@]} -gt 10 ]; then
        project_list="${project_list}... and $((${#public_projects[@]} - 10)) more"
    fi
    
    policies_json=$(echo "$policies_json" | jq \
        --arg title "Public Projects Found in Organization \`${AZURE_DEVOPS_ORG}\`" \
        --arg details "${#public_projects[@]} projects are set to public visibility (best practice review):\n$project_list" \
        --arg severity "4" \
        --arg next_steps "Review public projects to ensure they should be publicly accessible" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#projects_without_policies[@]} -gt 0 ]; then
    project_list=$(printf '%s\n' "${projects_without_policies[@]}")
    
    policies_json=$(echo "$policies_json" | jq \
        --arg title "Projects Without Branch Protection in Organization \`${AZURE_DEVOPS_ORG}\`" \
        --arg details "${#projects_without_policies[@]} sampled projects have no enabled branch protection policies (best practice):\n$project_list" \
        --arg severity "4" \
        --arg next_steps "Review and implement branch protection policies across all projects" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

if [ ${#insecure_service_connections[@]} -gt 0 ]; then
    conn_list=$(printf '%s\n' "${insecure_service_connections[@]}" | head -10)
    if [ ${#insecure_service_connections[@]} -gt 10 ]; then
        conn_list="${conn_list}... and $((${#insecure_service_connections[@]} - 10)) more"
    fi
    
    policies_json=$(echo "$policies_json" | jq \
        --arg title "Insecure Service Connections in Organization \`${AZURE_DEVOPS_ORG}\`" \
        --arg details "${#insecure_service_connections[@]} service connections may have security issues:\n$conn_list" \
        --arg severity "3" \
        --arg next_steps "Review service connection security settings and ensure proper authorization is configured" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# If no policy issues found, report healthy status to stdout only
if [ "$(echo "$policies_json" | jq '. | length')" -eq 0 ]; then
    echo "Organization policies and security settings appear to be properly configured for $AZURE_DEVOPS_ORG"
fi

# Write final JSON
echo "$policies_json" > "$OUTPUT_FILE"
echo "Organization policies analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== ORGANIZATION POLICIES SUMMARY ==="
echo "$policies_json" | jq -r '.[] | "Policy: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 