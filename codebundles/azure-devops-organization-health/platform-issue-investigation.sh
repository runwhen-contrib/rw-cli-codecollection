#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#
# This script:
#   1) Performs deep investigation of platform-wide issues
#   2) Correlates issues across different services
#   3) Provides detailed analysis for troubleshooting
#   4) Suggests remediation steps
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"

OUTPUT_FILE="platform_issue_investigation.json"
investigation_json='[]'

echo "Deep Platform Issue Investigation..."
echo "Organization: $AZURE_DEVOPS_ORG"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" --output none

# Investigate agent pool issues in detail
echo "Investigating agent pool issues..."
if agent_pools=$(az pipelines agent pool list --output json 2>/dev/null); then
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
        
        echo "  Investigating pool: $pool_name"
        
        if agents=$(az pipelines agent list --pool-id "$pool_id" --output json 2>/dev/null); then
            agent_count=$(echo "$agents" | jq '. | length')
            offline_agents=$(echo "$agents" | jq '[.[] | select(.status == "offline")]')
            offline_count=$(echo "$offline_agents" | jq '. | length')
            
            if [ "$offline_count" -gt 0 ]; then
                # Get details about offline agents
                offline_details=$(echo "$offline_agents" | jq -r '.[] | "Agent: \(.name), Version: \(.version // "unknown"), Last Contact: \(.statusChangedOn // "unknown")"')
                
                investigation_json=$(echo "$investigation_json" | jq \
                    --arg title "Offline Agents in Pool: $pool_name" \
                    --arg details "Pool $pool_name has $offline_count offline agents out of $agent_count total. Details: $offline_details" \
                    --arg severity "3" \
                    --arg next_steps "Check agent connectivity, restart agent services, and verify network connectivity for offline agents" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "severity": ($severity | tonumber),
                       "next_steps": $next_steps
                     }]')
            fi
            
            # Check for agents with old versions
            outdated_agents=$(echo "$agents" | jq '[.[] | select(.version != null and (.version | split(".")[0] | tonumber) < 2)]')
            outdated_count=$(echo "$outdated_agents" | jq '. | length')
            
            if [ "$outdated_count" -gt 0 ]; then
                investigation_json=$(echo "$investigation_json" | jq \
                    --arg title "Outdated Agents in Pool: $pool_name" \
                    --arg details "Pool $pool_name has $outdated_count agents running outdated versions" \
                    --arg severity "2" \
                    --arg next_steps "Update agent software to latest version for security and compatibility" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "severity": ($severity | tonumber),
                       "next_steps": $next_steps
                     }]')
            fi
        fi
    done
else
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Cannot Access Agent Pools for Investigation" \
        --arg details "Unable to access agent pools for detailed investigation" \
        --arg severity "3" \
        --arg next_steps "Verify permissions and connectivity to Azure DevOps services" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Investigate recent failures across projects
echo "Investigating recent failures across projects..."
if projects=$(az devops project list --output json 2>/dev/null); then
    project_count=$(echo "$projects" | jq '. | length')
    total_failures=0
    projects_with_failures=0
    
    # Check last 24 hours for failures
    from_date=$(date -d "24 hours ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    
    for ((i=0; i<project_count && i<5; i++)); do  # Limit to first 5 projects for performance
        project_json=$(jq -c ".[${i}]" <<< "$projects")
        project_name=$(echo "$project_json" | jq -r '.name')
        
        echo "  Checking failures in project: $project_name"
        
        if pipelines=$(az pipelines list --project "$project_name" --output json 2>/dev/null); then
            pipeline_count=$(echo "$pipelines" | jq '. | length')
            project_failures=0
            
            for ((j=0; j<pipeline_count && j<3; j++)); do  # Limit to first 3 pipelines per project
                pipeline_json=$(jq -c ".[${j}]" <<< "$pipelines")
                pipeline_id=$(echo "$pipeline_json" | jq -r '.id')
                
                if failed_runs=$(az pipelines runs list --pipeline-id "$pipeline_id" --query "[?result=='failed' && finishTime >= '$from_date']" --output json 2>/dev/null); then
                    failure_count=$(echo "$failed_runs" | jq '. | length')
                    project_failures=$((project_failures + failure_count))
                fi
            done
            
            if [ "$project_failures" -gt 0 ]; then
                projects_with_failures=$((projects_with_failures + 1))
                total_failures=$((total_failures + project_failures))
            fi
        fi
    done
    
    if [ "$total_failures" -gt 10 ]; then
        investigation_json=$(echo "$investigation_json" | jq \
            --arg title "High Failure Rate Across Organization" \
            --arg details "Detected $total_failures failures across $projects_with_failures projects in the last 24 hours" \
            --arg severity "3" \
            --arg next_steps "Investigate common causes of failures - check for platform issues, agent problems, or service disruptions" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Check for API rate limiting or performance issues
echo "Checking for API performance issues..."
start_time=$(date +%s)

# Perform several API calls to test responsiveness
test_calls=0
slow_calls=0

for i in {1..5}; do
    call_start=$(date +%s)
    az devops project list --output table >/dev/null 2>&1 && test_calls=$((test_calls + 1))
    call_end=$(date +%s)
    call_duration=$((call_end - call_start))
    
    if [ "$call_duration" -gt 3 ]; then
        slow_calls=$((slow_calls + 1))
    fi
    
    sleep 1
done

end_time=$(date +%s)
total_duration=$((end_time - start_time))

if [ "$slow_calls" -gt 2 ] || [ "$total_duration" -gt 20 ]; then
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "API Performance Issues Detected" \
        --arg details "API calls are slower than expected: $slow_calls out of $test_calls calls took >3 seconds, total test time: ${total_duration}s" \
        --arg severity "2" \
        --arg next_steps "Monitor Azure DevOps service status and consider rate limiting or network connectivity issues" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for service connection authentication issues
echo "Investigating service connection issues..."
auth_failures=0
total_connections=0

if projects=$(az devops project list --output json 2>/dev/null); then
    for ((i=0; i<project_count && i<3; i++)); do  # Check first 3 projects
        project_json=$(jq -c ".[${i}]" <<< "$projects")
        project_name=$(echo "$project_json" | jq -r '.name')
        
        if service_conns=$(az devops service-endpoint list --project "$project_name" --output json 2>/dev/null); then
            conn_count=$(echo "$service_conns" | jq '. | length')
            total_connections=$((total_connections + conn_count))
            
            # Check for connections with authentication issues (simplified check)
            for ((j=0; j<conn_count; j++)); do
                conn_json=$(jq -c ".[${j}]" <<< "$service_conns")
                is_ready=$(echo "$conn_json" | jq -r '.isReady // false')
                
                if [ "$is_ready" = "false" ]; then
                    auth_failures=$((auth_failures + 1))
                fi
            done
        fi
    done
fi

if [ "$auth_failures" -gt 0 ]; then
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Service Connection Authentication Issues" \
        --arg details "$auth_failures out of $total_connections service connections are not ready (may have authentication issues)" \
        --arg severity "3" \
        --arg next_steps "Review service connection configurations and refresh authentication credentials" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check for organization-level configuration issues
echo "Checking organization configuration..."
if ! org_info=$(az devops project list --output json 2>/dev/null); then
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Organization Access Issues" \
        --arg details "Cannot access basic organization information - may indicate authentication or permission problems" \
        --arg severity "4" \
        --arg next_steps "Verify service principal authentication and organization-level permissions" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# If no specific issues found, note that investigation was performed
if [ "$(echo "$investigation_json" | jq '. | length')" -eq 0 ]; then
    investigation_json=$(echo "$investigation_json" | jq \
        --arg title "Platform Investigation Complete" \
        --arg details "Deep platform investigation completed - no specific issues identified beyond initial alerts" \
        --arg severity "1" \
        --arg next_steps "Continue monitoring and review initial alerts for specific remediation steps" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$investigation_json" > "$OUTPUT_FILE"
echo "Platform issue investigation completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== PLATFORM INVESTIGATION SUMMARY ==="
echo "$investigation_json" | jq -r '.[] | "Finding: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\nNext Steps: \(.next_steps)\n---"' 