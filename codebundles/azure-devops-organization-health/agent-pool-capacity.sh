#!/usr/bin/env bash
set -euo pipefail
# NOTE: `set -x` is intentionally NOT used. It echoes the AZURE_DEVOPS_PAT into
# logs (a credential leak) and produces enormous output. Set AZ_DEBUG=1 to
# opt in to tracing for local debugging only.
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AGENT_UTILIZATION_THRESHOLD (optional, default: 80)
#   AUTH_TYPE (optional, default: service_principal)
#   AZURE_DEVOPS_PAT (required if AUTH_TYPE=pat)
#
# OPTIONAL ENV VARS:
#   EPHEMERAL_OFFLINE_RATIO  - % offline above which a pool with online capacity
#                              is treated as elastic/ephemeral churn (default 60)
#   AGENT_FETCH_PARALLELISM  - parallel agent-list calls (default 8)
#
# This script:
#   1) Analyzes all agent pools in the organization
#   2) Detects elastic (VMSS / scale-set) pools so transient offline agents are
#      not mis-reported as outages
#   3) Checks agent capacity and utilization
#   4) Identifies capacity bottlenecks
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AGENT_UTILIZATION_THRESHOLD:=80}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="agent_pool_capacity.json"
AGENT_CACHE_DIR="$(mktemp -d agentcap.XXXXXX)"
trap 'rm -rf "$AGENT_CACHE_DIR" agent_pools.json' EXIT
capacity_json='[]'

echo "Analyzing Agent Pool Capacity and Distribution..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Utilization Threshold: $AGENT_UTILIZATION_THRESHOLD%"

setup_azure_auth

# Identify elastic (VMSS/scale-set) pools up front so their transient offline
# agents are not counted as capacity failures.
echo "Detecting elastic (VMSS/scale-set) agent pools..."
load_elastic_pool_ids

# Get list of agent pools
echo "Getting agent pools..."
if ! agent_pools=$(az pipelines pool list --output json 2>pools_err.log); then
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

# Fetch agents for all non-hosted pools in parallel (major speedup for orgs
# with hundreds of pools that previously ran one sequential call per pool).
echo "Fetching agents for all self-hosted pools (parallelism: ${AGENT_FETCH_PARALLELISM:-20})..."
fetch_pool_agents_parallel "$agent_pools" "$AGENT_CACHE_DIR"

# Initialize counters
total_agents=0
total_online=0
total_busy=0
total_offline_effective=0   # offline agents that actually matter (excludes elastic/ephemeral churn)
pools_with_issues=0
elastic_pools=0
ephemeral_pools=0

# Analyze each agent pool
for ((i=0; i<pool_count; i++)); do
    pool_json=$(jq -c ".[${i}]" agent_pools.json)
    
    pool_id=$(echo "$pool_json" | jq -r '.id')
    pool_name=$(echo "$pool_json" | jq -r '.name')
    pool_type=$(echo "$pool_json" | jq -r '.poolType // "Unknown"')
    is_hosted=$(echo "$pool_json" | jq -r '.isHosted // false')
    
    # Skip Microsoft-hosted pools for capacity analysis
    if [ "$is_hosted" = "true" ]; then
        continue
    fi

    # Determine whether this is an elastic/VMSS pool BEFORE counting offline agents.
    if pool_is_elastic "$pool_json"; then
        is_elastic="true"
    else
        is_elastic="false"
    fi

    agents_file="$AGENT_CACHE_DIR/agents_${pool_id}.json"
    # Distinguish a real fetch failure (permission/timeout/throttle) from an
    # empty pool so inaccessible pools are reported rather than counted as empty.
    if fetch_err=$(agents_fetch_failed "$agents_file"); then
        capacity_json=$(echo "$capacity_json" | jq \
            --arg title "Unable To Retrieve Agents For Pool \`$pool_name\`" \
            --arg details "Failed to list agents for pool \`$pool_name\` (ID: $pool_id). This is an access/availability error, not an empty pool. Error: ${fetch_err:-unknown}" \
            --arg severity "3" \
            --arg nextStep "Verify the identity has the Agent Pools (Read) scope and 'Reader' on this pool, then re-run. Transient throttling/timeouts may also cause this." \
            '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
        echo "  WARNING: could not fetch agents for pool $pool_name ($pool_id): ${fetch_err:-unknown}"
        continue
    fi
    if [ ! -s "$agents_file" ]; then
        echo "[]" > "$agents_file"
    fi
    agents=$(cat "$agents_file")

    # VMSS-aware classification.
    eval "$(classify_pool_agents "$agents" "$is_elastic" "$pool_name")"
    agent_count=$AGENT_COUNT
    online_count=$ONLINE_COUNT
    offline_count=$OFFLINE_COUNT
    busy_count=$BUSY_COUNT
    pool_kind=$POOL_KIND
    expected_offline=$EXPECTED_OFFLINE

    # offline agents that represent genuine lost capacity (static pools only)
    actionable_offline=$((offline_count - expected_offline))
    [ "$actionable_offline" -lt 0 ] && actionable_offline=0

    echo "Analyzing pool: $pool_name (ID: $pool_id, Type: $pool_type, Kind: $pool_kind)"
    echo "  Agents: $agent_count total, $online_count online, $offline_count offline ($expected_offline expected for $pool_kind), $busy_count busy"

    # Calculate utilization on the online (servable) capacity
    if [ "$online_count" -gt 0 ]; then
        utilization=$(echo "scale=1; $busy_count * 100 / $online_count" | bc -l 2>/dev/null || echo "0")
    else
        utilization="0"
    fi
    echo "  Utilization: ${utilization}%"

    # Update org-wide totals
    total_agents=$((total_agents + agent_count))
    total_online=$((total_online + online_count))
    total_busy=$((total_busy + busy_count))
    total_offline_effective=$((total_offline_effective + actionable_offline))
    [ "$pool_kind" = "elastic" ] && elastic_pools=$((elastic_pools + 1))
    [ "$pool_kind" = "ephemeral" ] && ephemeral_pools=$((ephemeral_pools + 1))

    # Check for capacity issues
    pool_issues=()
    severity=4

    # No agents registered at all
    if [ "$agent_count" -eq 0 ]; then
        if [ "$pool_kind" = "elastic" ]; then
            echo "  Elastic pool with no agents currently provisioned (normal when idle)"
        else
            pool_issues+=("No agents configured")
            severity=3
        fi
    fi

    # No online capacity. For elastic/ephemeral pools this is only a problem when
    # work is actually waiting; a pool scaled to zero while idle is normal and the
    # offline backlog is expected churn. Static pools with all agents offline are
    # always a real problem.
    if [ "$agent_count" -gt 0 ] && [ "$online_count" -eq 0 ]; then
        if [ "$pool_kind" = "elastic" ] || [ "$pool_kind" = "ephemeral" ]; then
            if [ "$busy_count" -gt 0 ]; then
                pool_issues+=("No online agents but $busy_count assigned request(s) waiting (pool cannot service queued work)")
                if [ "$severity" -gt 2 ]; then severity=2; fi
            else
                echo "  $pool_kind pool scaled to zero (idle): 0 online, $offline_count expected offline, no queued work. Not flagged."
            fi
        else
            pool_issues+=("All agents offline")
            if [ "$severity" -gt 2 ]; then severity=2; fi
        fi
    fi

    # High utilization (only meaningful when there is online capacity)
    if [ "$online_count" -gt 0 ] && (( $(echo "$utilization >= $AGENT_UTILIZATION_THRESHOLD" | bc -l) )); then
        pool_issues+=("High utilization: ${utilization}%")
        if [ "$severity" -gt 2 ]; then severity=2; fi
    fi

    # Low capacity (only 1 agent online) - not meaningful for elastic pools that scale on demand
    if [ "$pool_kind" = "static" ] && [ "$online_count" -eq 1 ] && [ "$agent_count" -gt 1 ]; then
        pool_issues+=("Low capacity: only 1 agent online out of $agent_count")
        if [ "$severity" -gt 2 ]; then severity=2; fi
    fi

    # High offline ratio - ONLY for static pools. Elastic/ephemeral pools are
    # expected to carry a large offline backlog of torn-down instances.
    if [ "$pool_kind" = "static" ] && [ "$agent_count" -gt 1 ] && [ "$actionable_offline" -gt 0 ]; then
        offline_ratio=$(echo "scale=1; $actionable_offline * 100 / $agent_count" | bc -l 2>/dev/null || echo "0")
        if (( $(echo "$offline_ratio >= 50" | bc -l) )); then
            pool_issues+=("High offline ratio: ${offline_ratio}% ($actionable_offline of $agent_count)")
            if [ "$severity" -gt 2 ]; then severity=2; fi
        fi
    fi

    # Informational note for elastic/ephemeral pools carrying a large offline backlog
    if [ "$pool_kind" != "static" ] && [ "$offline_count" -gt 50 ]; then
        echo "  NOTE: $offline_count offline registrations are expected for a $pool_kind pool (torn-down scale-set/ephemeral agents). Not flagged as a capacity issue."
    fi

    # Add pool analysis to results - only create issues for pools with actual problems
    if [ ${#pool_issues[@]} -gt 0 ]; then
        pools_with_issues=$((pools_with_issues + 1))
        issues_summary=$(IFS='; '; echo "${pool_issues[*]}")
        title="Agent Pool Capacity Issue: $pool_name"
        
        capacity_json=$(echo "$capacity_json" | jq \
            --arg title "$title" \
            --arg pool_name "$pool_name" \
            --arg pool_id "$pool_id" \
            --arg pool_type "$pool_type" \
            --arg pool_kind "$pool_kind" \
            --arg agent_count "$agent_count" \
            --arg online_count "$online_count" \
            --arg offline_count "$offline_count" \
            --arg expected_offline "$expected_offline" \
            --arg busy_count "$busy_count" \
            --arg utilization "$utilization" \
            --arg issues_summary "$issues_summary" \
            --arg severity "$severity" \
            '. += [{
               "title": $title,
               "pool_name": $pool_name,
               "pool_id": $pool_id,
               "pool_type": $pool_type,
               "pool_kind": $pool_kind,
               "total_agents": ($agent_count | tonumber),
               "online_agents": ($online_count | tonumber),
               "offline_agents": ($offline_count | tonumber),
               "expected_offline_agents": ($expected_offline | tonumber),
               "busy_agents": ($busy_count | tonumber),
               "utilization_percent": $utilization,
               "issues_summary": $issues_summary,
               "severity": ($severity | tonumber),
               "details": "Pool \($pool_name) [\($pool_kind)]: \($agent_count) agents (\($online_count) online, \($busy_count) busy, \($offline_count) offline of which \($expected_offline) are expected scale-set/ephemeral churn). Utilization: \($utilization)%. Issues: \($issues_summary)",
               "next_steps": "Review agent pool \($pool_name) online capacity. For elastic/VMSS pools, verify the scale-set can provision agents; for static pools, investigate the offline agents and add capacity if utilization is high."
             }]')
    else
        echo "  Pool $pool_name capacity appears normal"
    fi
done

# Calculate overall organization capacity metrics
if [ "$total_online" -gt 0 ]; then
    overall_utilization=$(echo "scale=1; $total_busy * 100 / $total_online" | bc -l 2>/dev/null || echo "0")
else
    overall_utilization="0"
fi

# Add organization-wide capacity summary - only if there are issues
if [ "$pools_with_issues" -gt 0 ] || (( $(echo "$overall_utilization >= $AGENT_UTILIZATION_THRESHOLD" | bc -l) )); then
    org_severity=2
    org_title="Organization Agent Capacity Issues Detected"
    org_details="$pools_with_issues pools have capacity issues. Overall utilization: ${overall_utilization}%"
    
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
else
    echo "Organization agent capacity appears healthy across all pools"
fi

# Write final JSON (temp files are removed by the EXIT trap)
echo "$capacity_json" > "$OUTPUT_FILE"
echo "Agent pool capacity analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== AGENT POOL CAPACITY SUMMARY ==="
echo "Total Agents (incl. scale-set/ephemeral registrations): $total_agents"
echo "Online Agents: $total_online"
echo "Busy Agents: $total_busy"
echo "Actionable Offline Agents (static pools only): $total_offline_effective"
echo "Elastic (VMSS/scale-set) Pools: $elastic_pools"
echo "Ephemeral (self-managed VMSS/AKS/container) Pools: $ephemeral_pools"
echo "Overall Utilization: ${overall_utilization}%"
echo "Pools with Issues: $pools_with_issues"
echo ""
echo "$capacity_json" | jq -r '.[] | select(.organization_summary != true) | "Pool: \(.pool_name) [\(.pool_kind // "static")]\nAgents: \(.total_agents) total, \(.online_agents) online, \(.busy_agents) busy, \(.offline_agents) offline (\(.expected_offline_agents // 0) expected)\nUtilization: \(.utilization_percent)%\nIssues: \(.issues_summary)\n---"' 