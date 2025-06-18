#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#
# This script:
#   1) Analyzes cross-project dependencies
#   2) Checks shared resource usage
#   3) Identifies potential dependency issues
#   4) Reports on resource sharing patterns
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"

OUTPUT_FILE="cross_project_dependencies.json"
dependencies_json='[]'

echo "Analyzing Cross-Project Dependencies..."
echo "Organization: $AZURE_DEVOPS_ORG"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" --output none

# Get list of projects
echo "Getting projects..."
if ! projects=$(az devops project list --output json 2>projects_err.log); then
    err_msg=$(cat projects_err.log)
    rm -f projects_err.log
    
    echo "ERROR: Could not list projects."
    dependencies_json=$(echo "$dependencies_json" | jq \
        --arg title "Failed to List Projects" \
        --arg details "$err_msg" \
        --arg severity "3" \
        --arg next_steps "Check permissions to access projects" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$dependencies_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f projects_err.log

echo "$projects" > projects.json
project_count=$(jq '. | length' projects.json)

if [ "$project_count" -eq 0 ]; then
    echo "No projects found."
    dependencies_json='[{"title": "No Projects Found", "details": "No projects found in the organization", "severity": 2, "next_steps": "Verify project access permissions"}]'
    echo "$dependencies_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "Found $project_count projects. Analyzing dependencies..."

# Analyze shared agent pools usage
echo "Analyzing shared agent pool usage..."
if agent_pools=$(az pipelines agent pool list --output json 2>/dev/null); then
    shared_pools=()
    
    # Check each agent pool for usage across projects
    pool_count=$(echo "$agent_pools" | jq '. | length')
    
    for ((i=0; i<pool_count; i++)); do
        pool_json=$(jq -c ".[${i}]" <<< "$agent_pools")
        pool_name=$(echo "$pool_json" | jq -r '.name')
        pool_id=$(echo "$pool_json" | jq -r '.id')
        is_hosted=$(echo "$pool_json" | jq -r '.isHosted // false')
        
        # Skip Microsoft-hosted pools
        if [ "$is_hosted" = "true" ]; then
            continue
        fi
        
        echo "  Checking pool usage: $pool_name"
        
        # Count projects using this pool (this is an approximation)
        projects_using_pool=0
        
        for ((j=0; j<project_count; j++)); do
            project_json=$(jq -c ".[${j}]" projects.json)
            project_name=$(echo "$project_json" | jq -r '.name')
            
            # Check if project has pipelines using this pool
            if pipelines=$(az pipelines list --project "$project_name" --output json 2>/dev/null); then
                pipeline_count=$(echo "$pipelines" | jq '. | length')
                if [ "$pipeline_count" -gt 0 ]; then
                    projects_using_pool=$((projects_using_pool + 1))
                fi
            fi
        done
        
        if [ "$projects_using_pool" -gt 1 ]; then
            shared_pools+=("$pool_name:$projects_using_pool")
            echo "    Pool $pool_name is shared across $projects_using_pool projects"
        fi
    done
    
    if [ ${#shared_pools[@]} -gt 0 ]; then
        shared_pools_summary=$(IFS=', '; echo "${shared_pools[*]}")
        
        dependencies_json=$(echo "$dependencies_json" | jq \
            --arg title "Shared Agent Pools Detected" \
            --arg details "Agent pools shared across projects: $shared_pools_summary" \
            --arg severity "1" \
            --arg next_steps "Monitor shared agent pool capacity to ensure adequate resources for all dependent projects" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
else
    echo "  Could not analyze agent pool usage"
fi

# Analyze service connections sharing
echo "Analyzing service connection sharing..."
service_connections_by_name=()
declare -A connection_projects

for ((i=0; i<project_count; i++)); do
    project_json=$(jq -c ".[${i}]" projects.json)
    project_name=$(echo "$project_json" | jq -r '.name')
    
    echo "  Checking service connections in: $project_name"
    
    if service_conns=$(az devops service-endpoint list --project "$project_name" --output json 2>/dev/null); then
        conn_count=$(echo "$service_conns" | jq '. | length')
        
        if [ "$conn_count" -gt 0 ]; then
            # Extract connection names and types
            connection_names=$(echo "$service_conns" | jq -r '.[].name')
            
            while IFS= read -r conn_name; do
                if [ -n "$conn_name" ]; then
                    if [[ -v connection_projects["$conn_name"] ]]; then
                        connection_projects["$conn_name"]="${connection_projects["$conn_name"]},$project_name"
                    else
                        connection_projects["$conn_name"]="$project_name"
                    fi
                fi
            done <<< "$connection_names"
        fi
    fi
done

# Check for similarly named connections (potential duplicates)
duplicate_connections=()
for conn_name in "${!connection_projects[@]}"; do
    project_list="${connection_projects[$conn_name]}"
    project_count_for_conn=$(echo "$project_list" | tr ',' '\n' | wc -l)
    
    if [ "$project_count_for_conn" -gt 1 ]; then
        duplicate_connections+=("$conn_name")
        echo "    Connection '$conn_name' found in multiple projects: $project_list"
    fi
done

if [ ${#duplicate_connections[@]} -gt 0 ]; then
    duplicate_summary=$(IFS=', '; echo "${duplicate_connections[*]}")
    
    dependencies_json=$(echo "$dependencies_json" | jq \
        --arg title "Duplicate Service Connections" \
        --arg details "Service connections with similar names across projects: $duplicate_summary" \
        --arg severity "2" \
        --arg next_steps "Review duplicate service connections and consider consolidating or using organization-level connections" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Analyze repository dependencies (check for cross-project repository references)
echo "Analyzing repository dependencies..."
cross_repo_refs=0

for ((i=0; i<project_count; i++)); do
    project_json=$(jq -c ".[${i}]" projects.json)
    project_name=$(echo "$project_json" | jq -r '.name')
    
    echo "  Checking repositories in: $project_name"
    
    if repos=$(az repos list --project "$project_name" --output json 2>/dev/null); then
        repo_count=$(echo "$repos" | jq '. | length')
        
        if [ "$repo_count" -gt 0 ]; then
            # Check for pipeline definitions that might reference other projects
            if pipelines=$(az pipelines list --project "$project_name" --output json 2>/dev/null); then
                pipeline_count=$(echo "$pipelines" | jq '. | length')
                
                # This is a simplified check - in practice, you'd need to examine pipeline YAML
                # for cross-project repository references
                if [ "$pipeline_count" -gt 5 ]; then
                    cross_repo_refs=$((cross_repo_refs + 1))
                fi
            fi
        fi
    fi
done

if [ "$cross_repo_refs" -gt 0 ]; then
    dependencies_json=$(echo "$dependencies_json" | jq \
        --arg title "Potential Cross-Project Dependencies" \
        --arg details "$cross_repo_refs projects have complex pipeline configurations that may include cross-project dependencies" \
        --arg severity "1" \
        --arg next_steps "Review pipeline configurations for cross-project repository dependencies and ensure proper access controls" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for projects with similar names (potential organizational issues)
echo "Analyzing project naming patterns..."
similar_projects=()

for ((i=0; i<project_count; i++)); do
    project_json=$(jq -c ".[${i}]" projects.json)
    project_name=$(echo "$project_json" | jq -r '.name')
    
    # Look for projects with similar prefixes
    for ((j=i+1; j<project_count; j++)); do
        other_project_json=$(jq -c ".[${j}]" projects.json)
        other_project_name=$(echo "$other_project_json" | jq -r '.name')
        
        # Simple similarity check - same first 3 characters
        if [ ${#project_name} -gt 3 ] && [ ${#other_project_name} -gt 3 ]; then
            prefix1=$(echo "$project_name" | cut -c1-3)
            prefix2=$(echo "$other_project_name" | cut -c1-3)
            
            if [ "$prefix1" = "$prefix2" ]; then
                similar_projects+=("$project_name/$other_project_name")
            fi
        fi
    done
done

if [ ${#similar_projects[@]} -gt 0 ]; then
    similar_summary=$(IFS=', '; echo "${similar_projects[*]}")
    
    dependencies_json=$(echo "$dependencies_json" | jq \
        --arg title "Similar Project Names Detected" \
        --arg details "Projects with similar naming patterns: $similar_summary" \
        --arg severity "1" \
        --arg next_steps "Review project organization and consider if projects should be consolidated or have clearer naming conventions" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# If no dependency issues found, add a healthy status
if [ "$(echo "$dependencies_json" | jq '. | length')" -eq 0 ]; then
    dependencies_json=$(echo "$dependencies_json" | jq \
        --arg title "Cross-Project Dependencies: Well Organized" \
        --arg details "No significant cross-project dependency issues detected across $project_count projects" \
        --arg severity "1" \
        --arg next_steps "Continue monitoring cross-project dependencies as the organization grows" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Clean up temporary files
rm -f projects.json

# Write final JSON
echo "$dependencies_json" > "$OUTPUT_FILE"
echo "Cross-project dependencies analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== CROSS-PROJECT DEPENDENCIES SUMMARY ==="
echo "Projects Analyzed: $project_count"
echo "Shared Agent Pools: ${#shared_pools[@]}"
echo "Duplicate Service Connections: ${#duplicate_connections[@]}"
echo ""
echo "$dependencies_json" | jq -r '.[] | "Finding: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 