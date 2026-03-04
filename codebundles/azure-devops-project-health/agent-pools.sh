#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#
# OPTIONAL ENV VARS:
#   HIGH_UTILIZATION_THRESHOLD - Percentage threshold for agent utilization (default: 80)
#
# This script:
#   1) Lists all agent pools in the specified Azure DevOps organization
#   2) Checks the status of agents in each pool
#   3) Identifies offline, disabled, or unhealthy agents
#   4) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${HIGH_UTILIZATION_THRESHOLD:=80}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-$azure_devops_pat}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="agent_pools_issues.json"
issues_json='[]'
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"

echo "Analyzing Azure DevOps Agent Pools..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "High Utilization Threshold: ${HIGH_UTILIZATION_THRESHOLD}%"

setup_azure_auth

# Get list of agent pools
echo "Retrieving agent pools in organization..."
if ! az_with_retry az pipelines pool list --org "$ORG_URL" --output json; then
    echo "ERROR: Could not list agent pools."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Agent Pools" \
        --arg details "Azure DevOps API was unreachable or returned an error after $AZ_RETRY_COUNT retry attempts." \
        --arg severity "3" \
        --arg nextStep "Check if you have sufficient permissions to view agent pools. Verify Azure DevOps API availability and network connectivity." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_steps": $nextStep,
           "severity": ($severity | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
pools="$AZ_RESULT"

# Save pools to a file to avoid subshell issues
echo "$pools" > pools.json

# Get the number of pools
pool_count=$(jq '. | length' pools.json)

# Process each agent pool using a for loop instead of pipe to while
for ((i=0; i<pool_count; i++)); do
    pool_json=$(jq -c ".[$i]" pools.json)
    
    # Extract values from JSON using jq
    pool_id=$(echo "$pool_json" | jq -r '.id')
    pool_name=$(echo "$pool_json" | jq -r '.name')
    pool_type=$(echo "$pool_json" | jq -r '.poolType')
    is_hosted=$(echo "$pool_json" | jq -r '.isHosted')
    
    echo "Processing Agent Pool: $pool_name (ID: $pool_id, Type: $pool_type)"
    
    # Skip hosted pools as we can't manage their agents
    if [[ "$is_hosted" == "true" ]]; then
        echo "  Skipping hosted pool with name $pool_name"
        continue
    fi
    
    # Get agents in the pool
    if ! az_with_retry az pipelines agent list --pool-id "$pool_id" --org "$ORG_URL" --output json; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to List Agents in Pool \`$pool_name\`" \
            --arg details "Could not retrieve agents after $AZ_RETRY_COUNT attempts. API may be unreachable or permissions insufficient." \
            --arg severity "3" \
            --arg nextStep "Check if you have sufficient permissions to view agents in this pool. Verify Azure DevOps API availability." \
            '. += [{
               "title": $title,
               "details": $details,
               "next_steps": $nextStep,
               "severity": ($severity | tonumber)
             }]')
        continue
    fi
    agents="$AZ_RESULT"
    
    # Check if pool has no agents
    agent_count=$(echo "$agents" | jq '. | length')
    if [[ "$agent_count" -eq 0 ]]; then
        echo "  Pool $pool_name has no agents (this may be intentional)"
        continue
    fi
    
    # Check for offline agents
    offline_agents=$(echo "$agents" | jq '[.[] | select(.status != "online")]')
    offline_count=$(echo "$offline_agents" | jq '. | length')
    
    if [[ "$offline_count" -gt 0 ]]; then
        offline_names=$(echo "$offline_agents" | jq -r '.[].name' | tr '\n' ', ' | sed 's/,$//')
        offline_details="Pool \`$pool_name\` (Type: $pool_type) has $offline_count of $agent_count agents offline. Offline agents: $offline_names"
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Offline Agents Found in Pool \`$pool_name\` ($offline_count of $agent_count agents)" \
            --arg details "$offline_details" \
            --arg severity "3" \
            --arg nextStep "Check the agent machines ($offline_names) and restart the agent service if needed. Verify network connectivity between agents and Azure DevOps." \
            '. += [{
               "title": $title,
               "details": $details,
               "next_steps": $nextStep,
               "severity": ($severity | tonumber)
             }]')
    fi
    
    # Check for disabled agents - only report if they're offline AND disabled (likely problematic)
    disabled_offline_agents=$(echo "$agents" | jq '[.[] | select(.enabled == false and .status != "online")]')
    disabled_offline_count=$(echo "$disabled_offline_agents" | jq '. | length')
    
    if [[ "$disabled_offline_count" -gt 0 ]]; then
        disabled_names=$(echo "$disabled_offline_agents" | jq -r '.[].name' | tr '\n' ', ' | sed 's/,$//')
        disabled_details="Pool \`$pool_name\` has $disabled_offline_count agents that are both disabled and offline: $disabled_names. These agents are not contributing to pool capacity."
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Disabled and Offline Agents in Pool \`$pool_name\` ($disabled_offline_count agents)" \
            --arg details "$disabled_details" \
            --arg severity "4" \
            --arg nextStep "These agents ($disabled_names) are both disabled and offline. Enable and restart them if they should be available, or remove them from the pool if no longer needed." \
            '. += [{
               "title": $title,
               "details": $details,
               "next_steps": $nextStep,
               "severity": ($severity | tonumber)
             }]')
    fi
    
    # Check for agents with high job count (potentially overloaded)
    busy_agents=$(echo "$agents" | jq '[.[] | select(.assignedRequest != null)]')
    busy_count=$(echo "$busy_agents" | jq '. | length')
    total_online=$(echo "$agents" | jq '[.[] | select(.status == "online")] | length')
    
    # If more than HIGH_UTILIZATION_THRESHOLD% of agents are busy, flag as potential capacity issue
    if [[ "$total_online" -gt 0 && "$busy_count" -gt 0 ]]; then
        busy_percentage=$((busy_count * 100 / total_online))
        if [[ "$busy_percentage" -gt "$HIGH_UTILIZATION_THRESHOLD" ]]; then
            busy_details=$(echo "$busy_agents" | jq -c '[.[] | {name: .name, status: .status, enabled: .enabled}]')
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "High Agent Utilization in Pool \`$pool_name\`" \
                --arg details "Pool has $busy_count out of $total_online agents currently busy ($busy_percentage% utilization)" \
                --arg severity "2" \
                --arg nextStep "Consider adding more agents to this pool to handle the workload or optimize your pipelines to reduce build times." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_steps": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
        fi
    fi
done

# Clean up temporary file
rm -f pools.json

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps agent pool analysis completed. Saved results to $OUTPUT_FILE"
