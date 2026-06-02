#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#
# OPTIONAL ENV VARS:
#   HIGH_UTILIZATION_THRESHOLD - Percentage threshold for agent utilization (default: 80)
#   EPHEMERAL_OFFLINE_RATIO    - % offline above which a pool with online capacity
#                                is treated as elastic/ephemeral churn (default 60)
#   MAX_OFFLINE_DETAIL         - max offline agent names listed per pool (default 20)
#   QUEUE_AGING_THRESHOLD_MIN  - minutes a queued job must wait before a dynamic
#                                pool at 0 online is treated as a real outage (15)
#   CHECK_QUEUE_ON_ZERO        - "true"/"false": probe the pool job queue when a
#                                dynamic pool has 0 online agents (default true)
#
# This script:
#   1) Lists all agent pools in the specified Azure DevOps organization
#   2) Checks the status of agents in each pool
#   3) Identifies offline, disabled, or unhealthy agents
#   4) Outputs results in JSON format
#
# Severity policy (uniform with the organization-health agent-pool scripts):
#   * DYNAMIC pools (elastic/ephemeral): torn-down agents are EXPECTED. A pool at
#     0 online while idle is NOT an outage -- it is a sev-4 advisory at most.
#     Escalate above sev 4 ONLY with real evidence of impact: queued builds aging
#     past QUEUE_AGING_THRESHOLD_MIN (sev 2), or work assigned to offline agents
#     (sev 3).
#   * STATIC pools with offline agents keep a higher severity (lost capacity); the
#     issue text always explains the likely cause.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${HIGH_UTILIZATION_THRESHOLD:=80}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
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

# Pre-fetch job-request queues in parallel (same pattern as org agent-pool-capacity).
if [[ "${CHECK_QUEUE_ON_ZERO:-true}" == "true" ]]; then
    nonhosted_pool_ids=$(jq -r '.[] | select((.isHosted // false) == false) | .id' pools.json)
    echo "Pre-fetching job-request queues for self-hosted pools (parallelism: ${AGENT_FETCH_PARALLELISM:-20})..."
    fetch_pool_job_requests_parallel "$nonhosted_pool_ids" "$AGENT_CACHE_DIR"
fi

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
        # complete lack of online capacity *while work is actually waiting*.
        if [[ "$online_count" -eq 0 ]]; then
            # Probe the job queue. Aging queued work (not busy_assigned) is the
            # real outage signal: a job waiting with no online agent can't be
            # "assigned" anywhere, so busy_assigned stays 0 even during an outage.
            QUEUED_TOTAL=0; QUEUED_AGING=0; OLDEST_QUEUED_MIN=0
            if [[ "${CHECK_QUEUE_ON_ZERO:-true}" == "true" ]]; then
                eval "$(pool_queue_pressure "$(load_pool_job_requests_json "$AGENT_CACHE_DIR/jobreqs_${pool_id}.json")" "${QUEUE_AGING_THRESHOLD_MIN:-15}")"
            fi
            queue_status="$(pool_queue_status_line "$busy_count" "$QUEUED_TOTAL" "$QUEUED_AGING" "$OLDEST_QUEUED_MIN")"

            # ESCALATION CONDITION (intent): escalate above sev 4 only with real
            # evidence of impact -- aging queued work (sev 2) or work bound to
            # offline agents (sev 3). Otherwise this is expected scale-down (sev 4).
            if [[ "$QUEUED_AGING" -gt 0 ]]; then
                pool_details=$(ado_pool_issue_details \
                    "Dynamic pool has 0 online agents AND $QUEUED_AGING queued build(s) aging past ${QUEUE_AGING_THRESHOLD_MIN:-15} min -- pipelines are blocked." \
                    "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                    "$offline_count" "$busy_count" "$offline_count" \
                    "Oldest queued job has waited ${OLDEST_QUEUED_MIN} min with no agent to run it." "" \
                    "$POOL_KIND_REASON" "$queue_status")
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Elastic Pool \`$pool_name\` Has Queued Builds But No Online Agents" \
                    --arg details "$pool_details" \
                    --arg severity "2" \
                    --arg nextStep "The dynamic scaler is not provisioning agents. Check the elastic pool sizing, backing Azure scale set / KEDA health, and the associated service connection." \
                    '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
            elif [[ "$busy_count" -gt 0 ]]; then
                pool_details=$(ado_pool_issue_details \
                    "Dynamic pool has 0 online agents but $busy_count agent(s) still carry an assignedRequest." \
                    "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                    "$offline_count" "$busy_count" "$offline_count" \
                    "No queued work is aging; an assignedRequest on an offline agent is usually a stale scale-down record." "" \
                    "$POOL_KIND_REASON" "$queue_status")
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Elastic Pool \`$pool_name\` Has Work Assigned To Offline Agents" \
                    --arg details "$pool_details" \
                    --arg severity "3" \
                    --arg nextStep "Confirm the scaler replaced the torn-down agents. If the assignedRequest persists, re-queue the job or verify the backing VMSS/Kubernetes infrastructure." \
                    '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
            else
                pool_details=$(ado_pool_issue_details \
                    "Elastic/ephemeral pool is scaled to zero (0 online, $offline_count offline registrations). No queued work and no assignedRequest detected." \
                    "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                    "$offline_count" "$busy_count" "$offline_count" \
                    "Advisory only -- expected idle autoscaling. No pipelines are waiting on this pool." "" \
                    "$POOL_KIND_REASON" "$queue_status")
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Elastic Pool \`$pool_name\` Scaled To Zero (Expected Dynamic Scale-Down)" \
                    --arg details "$pool_details" \
                    --arg severity "4" \
                    --arg nextStep "No action needed -- a dynamic pool idle at 0 online agents is expected. If builds later queue without starting, verify autoscale rules, backing VMSS/Kubernetes health, and service connections." \
                    '. += [{"title": $title, "details": $details, "next_steps": $nextStep, "severity": ($severity | tonumber)}]')
                echo "  Elastic/ephemeral pool \`$pool_name\` scaled to zero: sev-4 advisory (expected, no queued work)."
            fi
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
            "$offline_count" "$busy_count" "0" "" "$offline_names" \
            "$POOL_KIND_REASON" "")

        issues_json=$(echo "$issues_json" | jq \
            --arg title "Offline Agents Found in Pool \`$pool_name\` ($offline_count of $agent_count agents)" \
            --arg details "$pool_details" \
            --arg severity "3" \
            --arg nextStep "These are persistent/static agents: restart the agent service on each offline host, confirm the host is powered on and can reach dev.azure.com, and verify the agent credentials/PAT have not expired. If this is actually an autoscaled VMSS pool, configure Azure DevOps to remove torn-down agents automatically." \
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
