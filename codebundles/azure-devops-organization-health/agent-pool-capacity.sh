#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AGENT_UTILIZATION_THRESHOLD (optional, default: 80)
#
# This script:
#   1) Analyzes all agent pools in the organization
#   2) Checks agent capacity and utilization
#   3) Identifies capacity bottlenecks
#   4) Reports distribution and availability issues
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AGENT_UTILIZATION_THRESHOLD:=80}"

OUTPUT_FILE="agent_pool_capacity.json"
capacity_json='[]'

echo "Analyzing Agent Pool Capacity and Distribution..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Utilization Threshold: $AGENT_UTILIZATION_THRESHOLD%"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" --output none

# Get list of agent pools
echo "Getting agent pools..."
if ! agent_pools=$(az pipelines agent pool list --output json 2>pools_err.log); then
    err_msg=$(cat pools_err.log)
    rm -f pools_err.log
    
    echo "ERROR: Could not list agent pools."
    capacity_json=$(echo "$capacity_json" | jq \
        --arg title "Failed to List Agent Pools" \
        --arg details "$err_msg" \
        --arg severity "4" \
        --arg next_steps "Check organization permissions and verify access to agent pools" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$capacity_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f pools_err.log

echo "$agent_pools" > agent_pools.json
pool_count=$(jq '. | length' agent_pools.json)

if [ "$pool_count" -eq 0 ]; then
    echo "No agent pools found."
    capacity_json='[{"title": "No Agent Pools Found", "details": "No agent pools found in the organization", "severity": 3, "next_steps": "Create agent pools or verify permissions to view existing pools"}]'
    echo "$capacity_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "Found $pool_count agent pools. Analyzing capacity..."

# Initialize counters
total_agents=0
total_online=0
total_busy=0
pools_with_issues=0

# Analyze each agent pool
for ((i=0; i<pool_count; i++)); do
    pool_json=$(jq -c ".[${i}]" agent_pools.json)
    
    pool_id=$(echo "$pool_json" | jq -r '.id')
    pool_name=$(echo "$pool_json" | jq -r '.name')
    pool_type=$(echo "$pool_json" | jq -r '.poolType // "Unknown"')
    is_hosted=$(echo "$pool_json" | jq -r '.isHosted // false')
    
    echo "Analyzing pool: $pool_name (ID: $pool_id, Type: $pool_type, Hosted: $is_hosted)"
    
    # Skip Microsoft-hosted pools for capacity analysis
    if [ "$is_hosted" = "true" ]; then
        echo "  Skipping Microsoft-hosted pool"
        continue
    fi
    
    # Get agents in this pool
    if ! agents=$(az pipelines agent list --pool-id "$pool_id" --output json 2>agents_err.log); then
        err_msg=$(cat agents_err.log)
        rm -f agents_err.log
        
        capacity_json=$(echo "$capacity_json" | jq \
            --arg title "Cannot Access Agents in Pool: $pool_name" \
            --arg details "Failed to get agents for pool $pool_name: $err_msg" \
            --arg severity "3" \
            --arg next_steps "Check permissions for agent pool $pool_name" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
        continue
    fi
    rm -f agents_err.log
    
    # Analyze agent status
    agent_count=$(echo "$agents" | jq '. | length')
    online_count=$(echo "$agents" | jq '[.[] | select(.status == "online")] | length')
    offline_count=$(echo "$agents" | jq '[.[] | select(.status == "offline")] | length')
    busy_count=$(echo "$agents" | jq '[.[] | select(.assignedRequest != null)] | length')
    
    # Calculate utilization
    if [ "$online_count" -gt 0 ]; then
        utilization=$(echo "scale=1; $busy_count * 100 / $online_count" | bc -l 2>/dev/null || echo "0")
    else
        utilization="0"
    fi
    
    echo "  Agents: $agent_count total, $online_count online, $offline_count offline, $busy_count busy"
    echo "  Utilization: ${utilization}%"
    
    # Update totals
    total_agents=$((total_agents + agent_count))
    total_online=$((total_online + online_count))
    total_busy=$((total_busy + busy_count))
    
    # Check for capacity issues
    pool_issues=()
    severity=1
    
    # No agents in pool
    if [ "$agent_count" -eq 0 ]; then
        pool_issues+=("No agents configured")
        severity=3
        pools_with_issues=$((pools_with_issues + 1))
    fi
    
    # All agents offline
    if [ "$agent_count" -gt 0 ] && [ "$online_count" -eq 0 ]; then
        pool_issues+=("All agents offline")
        severity=4
        pools_with_issues=$((pools_with_issues + 1))
    fi
    
    # High utilization
    if [ "$online_count" -gt 0 ] && (( $(echo "$utilization >= $AGENT_UTILIZATION_THRESHOLD" | bc -l) )); then
        pool_issues+=("High utilization: ${utilization}%")
        severity=2
        pools_with_issues=$((pools_with_issues + 1))
    fi
    
    # Low capacity (only 1 agent online)
    if [ "$online_count" -eq 1 ] && [ "$agent_count" -gt 1 ]; then
        pool_issues+=("Low capacity: only 1 agent online out of $agent_count")
        severity=2
        pools_with_issues=$((pools_with_issues + 1))
    fi
    
    # High offline ratio
    if [ "$agent_count" -gt 1 ] && [ "$offline_count" -gt 0 ]; then
        offline_ratio=$(echo "scale=1; $offline_count * 100 / $agent_count" | bc -l 2>/dev/null || echo "0")
        if (( $(echo "$offline_ratio >= 50" | bc -l) )); then
            pool_issues+=("High offline ratio: ${offline_ratio}%")
            severity=2
            pools_with_issues=$((pools_with_issues + 1))
        fi
    fi
    
    # Add pool analysis to results
    if [ ${#pool_issues[@]} -gt 0 ]; then
        issues_summary=$(IFS='; '; echo "${pool_issues[*]}")
        title="Agent Pool Capacity Issue: $pool_name"
    else
        issues_summary="Pool capacity appears normal"
        title="Agent Pool Capacity: $pool_name - Normal"
    fi
    
    capacity_json=$(echo "$capacity_json" | jq \
        --arg title "$title" \
        --arg pool_name "$pool_name" \
        --arg pool_id "$pool_id" \
        --arg pool_type "$pool_type" \
        --arg agent_count "$agent_count" \
        --arg online_count "$online_count" \
        --arg offline_count "$offline_count" \
        --arg busy_count "$busy_count" \
        --arg utilization "$utilization" \
        --arg issues_summary "$issues_summary" \
        --arg severity "$severity" \
        '. += [{
           "title": $title,
           "pool_name": $pool_name,
           "pool_id": $pool_id,
           "pool_type": $pool_type,
           "total_agents": ($agent_count | tonumber),
           "online_agents": ($online_count | tonumber),
           "offline_agents": ($offline_count | tonumber),
           "busy_agents": ($busy_count | tonumber),
           "utilization_percent": $utilization,
           "issues_summary": $issues_summary,
           "severity": ($severity | tonumber),
           "details": "Pool \($pool_name): \($agent_count) agents (\($online_count) online, \($busy_count) busy). Utilization: \($utilization)%. Issues: \($issues_summary)",
           "next_steps": "Review agent pool \($pool_name) capacity and consider adding more agents or investigating offline agents"
         }]')
done

# Calculate overall organization capacity metrics
if [ "$total_online" -gt 0 ]; then
    overall_utilization=$(echo "scale=1; $total_busy * 100 / $total_online" | bc -l 2>/dev/null || echo "0")
else
    overall_utilization="0"
fi

# Add organization-wide capacity summary
if [ "$pools_with_issues" -gt 0 ] || (( $(echo "$overall_utilization >= $AGENT_UTILIZATION_THRESHOLD" | bc -l) )); then
    org_severity=2
    org_title="Organization Agent Capacity Issues Detected"
    org_details="$pools_with_issues pools have capacity issues. Overall utilization: ${overall_utilization}%"
else
    org_severity=1
    org_title="Organization Agent Capacity: Healthy"
    org_details="Agent capacity appears adequate across all pools. Overall utilization: ${overall_utilization}%"
fi

capacity_json=$(echo "$capacity_json" | jq \
    --arg title "$org_title" \
    --arg total_agents "$total_agents" \
    --arg total_online "$total_online" \
    --arg total_busy "$total_busy" \
    --arg overall_utilization "$overall_utilization" \
    --arg pools_with_issues "$pools_with_issues" \
    --arg org_details "$org_details" \
    --arg severity "$org_severity" \
    '. += [{
       "title": $title,
       "organization_summary": true,
       "total_agents": ($total_agents | tonumber),
       "total_online": ($total_online | tonumber),
       "total_busy": ($total_busy | tonumber),
       "overall_utilization_percent": $overall_utilization,
       "pools_with_issues": ($pools_with_issues | tonumber),
       "details": $org_details,
       "severity": ($severity | tonumber),
       "next_steps": "Monitor agent capacity trends and plan for additional capacity if utilization remains high"
     }]')

# Clean up temporary files
rm -f agent_pools.json

# Write final JSON
echo "$capacity_json" > "$OUTPUT_FILE"
echo "Agent pool capacity analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== AGENT POOL CAPACITY SUMMARY ==="
echo "Total Agents: $total_agents"
echo "Online Agents: $total_online"
echo "Busy Agents: $total_busy"
echo "Overall Utilization: ${overall_utilization}%"
echo "Pools with Issues: $pools_with_issues"
echo ""
echo "$capacity_json" | jq -r '.[] | select(.organization_summary != true) | "Pool: \(.pool_name)\nAgents: \(.total_agents) total, \(.online_agents) online, \(.busy_agents) busy\nUtilization: \(.utilization_percent)%\nIssues: \(.issues_summary)\n---"' 