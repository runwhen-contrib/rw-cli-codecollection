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
AGENT_CACHE_DIR="$(mktemp -d agentpools.XXXXXX)"
trap 'rm -rf "$AGENT_CACHE_DIR" pools.json' EXIT

echo "Analyzing Azure DevOps Agent Pools..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "High Utilization Threshold: ${HIGH_UTILIZATION_THRESHOLD}%"

setup_azure_auth

# Detect elastic (VMSS/scale-set) pools so their transient offline agents are
# not mis-reported as outages.
echo "Detecting elastic (VMSS/scale-set) agent pools..."
load_elastic_pool_ids

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

# Fetch agents for all non-hosted pools in parallel (much faster than a
# sequential call per pool when an organisation has many pools).
echo "Fetching agents for all self-hosted pools (parallelism: ${AGENT_FETCH_PARALLELISM:-20})..."
fetch_pool_agents_parallel "$pools" "$AGENT_CACHE_DIR"

# Process each agent pool using a for loop instead of pipe to while
for ((i=0; i<pool_count; i++)); do
    pool_json=$(jq -c ".[$i]" pools.json)
    
    # Extract values from JSON using jq
    pool_id=$(echo "$pool_json" | jq -r '.id')
    pool_name=$(echo "$pool_json" | jq -r '.name')
    pool_type=$(echo "$pool_json" | jq -r '.poolType')
    is_hosted=$(echo "$pool_json" | jq -r '.isHosted')
    
    # Skip hosted pools as we can't manage their agents
    if [[ "$is_hosted" == "true" ]]; then
        echo "  Skipping hosted pool with name $pool_name"
        continue
    fi

    if pool_is_elastic "$pool_json"; then
        is_elastic="true"
    else
        is_elastic="false"
    fi

    agents_file="$AGENT_CACHE_DIR/agents_${pool_id}.json"
    # Distinguish a real fetch failure (permission/timeout/throttle) from an
    # empty pool so we don't silently report inaccessible pools as healthy.
    if fetch_err=$(agents_fetch_failed "$agents_file"); then
        pool_details=$(ado_pool_issue_details \
            "Failed to list agents for pool \`$pool_name\` (id=$pool_id). This is an access/availability error, not an empty pool." \
            "$pool_name" "$pool_id" "$pool_type" "unknown" "0" "0" "0" "0" "0" \
            "Fetch error: ${fetch_err:-unknown}. The task tried REST first, then az pipelines agent list as fallback." "")
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Unable To Retrieve Agents For Pool \`$pool_name\`" \
            --arg details "$pool_details" \
            --arg severity "3" \
            --arg nextStep "Verify the identity has the Agent Pools (Read) scope and 'Reader' on this pool, then re-run. Transient throttling/timeouts may also cause this." \
            '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
        echo "  WARNING: could not fetch agents for pool $pool_name ($pool_id): ${fetch_err:-unknown}"
        continue
    fi
    agents=$(load_pool_agents_json "$agents_file")

    # VMSS-aware classification of online/offline/busy.
    eval "$(classify_pool_agents "$agents" "$is_elastic" "$pool_name")"
    agent_count=$AGENT_COUNT
    online_count=$ONLINE_COUNT
    offline_count=$OFFLINE_COUNT
    busy_count=$BUSY_COUNT
    pool_kind=$POOL_KIND

    echo "Processing Agent Pool: $pool_name (ID: $pool_id, Type: $pool_type, Kind: $pool_kind) -> $online_count online / $offline_count offline / $agent_count total"

    # Check if pool has no agents
    if [[ "$agent_count" -eq 0 ]]; then
        echo "  Pool $pool_name has no agents (this may be intentional)"
        continue
    fi

    if [[ "$pool_kind" == "elastic" || "$pool_kind" == "ephemeral" ]]; then
        # Elastic/VMSS/ephemeral pool: offline agents are torn-down scale-set
        # instances and must NOT be flagged. The only actionable failure is a
        # complete lack of online capacity *while work is waiting*.
        if [[ "$online_count" -eq 0 && "$busy_count" -gt 0 ]]; then
            pool_details=$(ado_pool_issue_details \
                "Elastic/ephemeral pool has 0 online agents but $busy_count agent(s) with an active assignedRequest — work is bound to offline/unavailable agents." \
                "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                "$offline_count" "$busy_count" "$offline_count" \
                "Action: verify the scaler can provision online agents immediately." "")
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Elastic Pool \`$pool_name\` Has No Online Agents While Work Is Assigned" \
                --arg details "$pool_details" \
                --arg severity "2" \
                --arg nextStep "Verify the VMSS/scale-set/Kubernetes scaler can provision agents: check the elastic pool sizing, backing Azure scale set / KEDA health, and the associated service connection." \
                '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
        elif [[ "$online_count" -eq 0 ]]; then
            pool_details=$(ado_pool_issue_details \
                "Elastic/ephemeral pool is scaled to zero (0 online, $offline_count offline registrations). No assignedRequest detected on registered agents." \
                "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                "$offline_count" "$busy_count" "$offline_count" \
                "Advisory: this is often normal idle autoscaling. If pipeline runs are queued for this pool in Azure DevOps, treat as a capacity incident and investigate autoscale/VMSS/KEDA." "")
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Elastic Pool \`$pool_name\` Scaled To Zero (Verify Queue)" \
                --arg details "$pool_details" \
                --arg severity "4" \
                --arg nextStep "If no pipelines are waiting, no action needed. If builds are queued for this pool, verify autoscale rules, backing VMSS/Kubernetes health, and service connections." \
                '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
            echo "  Elastic/ephemeral pool \`$pool_name\` scaled to zero: advisory issue raised (verify queue if pipelines are waiting)."
        else
            echo "  Elastic/ephemeral pool healthy: $online_count online agent(s); ignoring $offline_count expected offline registrations."
        fi
    elif [[ "$offline_count" -gt 0 ]]; then
        # Static pool: offline agents are genuine lost capacity. Cap the
        # enumerated name list to keep output bounded.
        max_names="${MAX_OFFLINE_DETAIL:-20}"
        # Match classify_pool_agents' offline definition (status == "offline")
        # so the enumerated names are consistent with $offline_count.
        offline_names=$(echo "$agents" | jq -r --argjson n "$max_names" \
            '[.[] | select(.status == "offline")][:$n][].name' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
        if [[ "$offline_count" -gt "$max_names" ]]; then
            offline_names="$offline_names, ... (+$((offline_count - max_names)) more)"
        fi
        pool_details=$(ado_pool_issue_details \
            "Static pool has $offline_count of $agent_count agents offline (actionable lost capacity)." \
            "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
            "$offline_count" "$busy_count" "0" "" "$offline_names")

        issues_json=$(echo "$issues_json" | jq \
            --arg title "Offline Agents Found in Pool \`$pool_name\` ($offline_count of $agent_count agents)" \
            --arg details "$pool_details" \
            --arg severity "3" \
            --arg nextStep "Check the offline agent machines and restart the agent service if needed. Verify network connectivity between agents and Azure DevOps. If this is an autoscaled VMSS pool, configure Azure DevOps to remove torn-down agents automatically." \
            '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')

        # Disabled AND offline agents (static pools only)
        disabled_offline_count=$(echo "$agents" | jq '[.[] | select(.enabled == false and .status == "offline")] | length')
        if [[ "$disabled_offline_count" -gt 0 ]]; then
            disabled_names=$(echo "$agents" | jq -r --argjson n "$max_names" \
                '[.[] | select(.enabled == false and .status == "offline")][:$n][].name' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Disabled and Offline Agents in Pool \`$pool_name\` ($disabled_offline_count agents)" \
                --arg details "Pool \`$pool_name\` has $disabled_offline_count agents that are both disabled and offline: $disabled_names. These agents are not contributing to pool capacity." \
                --arg severity "4" \
                --arg nextStep "Enable and restart these agents if they should be available, or remove them from the pool if no longer needed." \
                '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
        fi
    fi

    # High utilization on online (servable) capacity - meaningful for all pool kinds
    if [[ "$online_count" -gt 0 && "$busy_count" -gt 0 ]]; then
        busy_percentage=$((busy_count * 100 / online_count))
        if [[ "$busy_percentage" -gt "$HIGH_UTILIZATION_THRESHOLD" ]]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "High Agent Utilization in Pool \`$pool_name\`" \
                --arg details "Pool has $busy_count out of $online_count online agents currently busy ($busy_percentage% utilization)" \
                --arg severity "2" \
                --arg nextStep "Consider adding more agents to this pool to handle the workload or optimize your pipelines to reduce build times." \
                '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
        fi
    fi
done

# Write final JSON (temp files removed by EXIT trap)
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps agent pool analysis completed. Saved results to $OUTPUT_FILE"
