#!/usr/bin/env bash
set -euo pipefail
# NOTE: `set -x` is intentionally NOT used here. It leaks the AZURE_DEVOPS_PAT
# into logs and, combined with large agent pools, generated tens of MB of output.
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AUTH_TYPE (optional, default: service_principal)
#   AZURE_DEVOPS_PAT (required if AUTH_TYPE=pat)
#
# OPTIONAL ENV VARS:
#   EPHEMERAL_OFFLINE_RATIO  - % offline above which a pool with online capacity
#                              is treated as elastic/ephemeral churn (default 60)
#   AGENT_FETCH_PARALLELISM  - parallel agent-list calls (default 8)
#   MAX_OFFLINE_DETAIL       - max offline agent names listed per pool (default 20)
#   QUEUE_AGING_THRESHOLD_MIN- minutes a queued job must wait before a dynamic
#                              pool at 0 online is treated as a real outage (15)
#   CHECK_QUEUE_ON_ZERO      - "true"/"false": probe the pool job queue when a
#                              dynamic pool has 0 online agents (default true)
#
# This script:
#   1) Performs deep investigation of platform-wide issues
#   2) Detects elastic/VMSS pools so transient offline agents are not flagged
#   3) Correlates issues across different services
#   4) Suggests remediation steps
#
# Severity policy mirrors agent-pool-capacity.sh: DYNAMIC pools torn-down agents
# are expected (sev 4 advisory at most when idle); escalate only on aging queued
# work (sev 2) or work assigned to offline agents (sev 3). STATIC pools with
# offline agents keep a higher severity but always explain the likely cause.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AUTH_TYPE:=service_principal}"
: "${MAX_OFFLINE_DETAIL:=20}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="platform_issue_investigation.json"
investigation_json='[]'
: "${MAX_POOLS:=500}"
: "${AGENT_FETCH_PARALLELISM:=32}"
# Reuse the SAME stable cache dir as agent-pool-capacity.sh so this task (which
# runs later in the org runbook) inherits its already-fetched pool agents within
# the TTL instead of re-scanning every pool from scratch.
AGENT_CACHE_DIR="${ADO_AGENT_CACHE_DIR:-.ado_agent_cache}"
mkdir -p "$AGENT_CACHE_DIR"

echo "Deep Platform Issue Investigation..."
echo "Organization: $AZURE_DEVOPS_ORG"

setup_azure_auth

# Investigate agent pool issues in detail
echo "Detecting elastic (VMSS/scale-set) agent pools..."
load_elastic_pool_ids

echo "Investigating agent pool issues..."
if agent_pools=$(az pipelines pool list --output json 2>/dev/null); then
    pool_count=$(echo "$agent_pools" | jq '. | length')

    # Bound the deep scan on very large orgs so the task completes within its
    # timeout (non-hosted pools first; hosted are skipped for this analysis).
    total_pool_count=$pool_count
    if [ "$pool_count" -gt "$MAX_POOLS" ]; then
        agent_pools=$(echo "$agent_pools" | jq --argjson n "$MAX_POOLS" 'sort_by(.isHosted // false) | .[:$n]')
        pool_count=$(echo "$agent_pools" | jq '. | length')
        investigation_json=$(echo "$investigation_json" | jq \
            --arg title "Platform Pool Scan Bounded (Large Organization)" \
            --arg details "Organization has $total_pool_count agent pools; this run deep-scanned the first $pool_count (non-hosted first, MAX_POOLS=$MAX_POOLS) to stay within the task timeout." \
            --arg severity "4" \
            --arg nextStep "No action needed for monitoring. To deep-scan all $total_pool_count pools in one run, raise MAX_POOLS and the task timeout." \
            '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $nextStep}]')
    fi

    # Fetch all pool agents in parallel rather than one slow call per pool. Fresh
    # files left by agent-pool-capacity.sh in the shared cache are reused (TTL).
    echo "  Fetching agents for $pool_count pools (parallelism: ${AGENT_FETCH_PARALLELISM:-20})..."
    fetch_pool_agents_parallel "$agent_pools" "$AGENT_CACHE_DIR"

    # Pre-fetch job-request queues in parallel. The queue probe is only consumed
    # for pools at 0 online agents, so restrict the calls to just those pools.
    if [ "${CHECK_QUEUE_ON_ZERO:-true}" = "true" ]; then
        nonhosted_pool_ids=$(echo "$agent_pools" | jq -r '.[] | select((.isHosted // false) == false) | .id')
        queue_probe_ids=$(pools_with_zero_online "$nonhosted_pool_ids" "$AGENT_CACHE_DIR")
        probe_n=$(printf '%s\n' "$queue_probe_ids" | grep -cE '^[0-9]+$' || true)
        echo "  Pre-fetching job-request queues for ${probe_n:-0} scaled-to-zero pool(s) (parallelism: ${AGENT_FETCH_PARALLELISM:-20})..."
        [ -n "$queue_probe_ids" ] && fetch_pool_job_requests_parallel "$queue_probe_ids" "$AGENT_CACHE_DIR"
    fi

    # Clustered findings: emit one issue per category after the loop instead of
    # one per pool (an org with hundreds of pools otherwise floods the report).
    # Genuine, rare signals (aging queued work, work assigned to offline agents)
    # stay per-pool below.
    declare -a static_offline=()    # static pools with offline agents (lost capacity)
    declare -a elastic_idle=()      # elastic/ephemeral scaled to zero (expected)
    declare -a outdated_agents=()   # pools running outdated agent versions

    for ((i=0; i<pool_count; i++)); do
        pool_json=$(jq -c ".[${i}]" <<< "$agent_pools")
        pool_name=$(echo "$pool_json" | jq -r '.name')
        pool_id=$(echo "$pool_json" | jq -r '.id')
        pool_type=$(echo "$pool_json" | jq -r '.poolType // "Unknown"')
        is_hosted=$(echo "$pool_json" | jq -r '.isHosted // false')
        
        # Skip Microsoft-hosted pools
        if [ "$is_hosted" = "true" ]; then
            continue
        fi

        if pool_is_elastic "$pool_json"; then
            is_elastic="true"
        else
            is_elastic="false"
        fi

        agents_file="$AGENT_CACHE_DIR/agents_${pool_id}.json"
        # A fetch failure (permission/timeout/throttle) is reported as an
        # access issue rather than being treated as an empty pool.
        if fetch_err=$(agents_fetch_failed "$agents_file"); then
            pool_details=$(ado_pool_issue_details \
                "Failed to list agents for pool $pool_name (id=$pool_id). Access/availability error." \
                "$pool_name" "$pool_id" "$pool_type" "unknown" "0" "0" "0" "0" "0" \
                "Fetch error: ${fetch_err:-unknown}" "")
            investigation_json=$(echo "$investigation_json" | jq \
                --arg title "Unable To Retrieve Agents For Pool: $pool_name" \
                --arg details "$pool_details" \
                --arg severity "3" \
                --arg next_steps "Verify the identity has the Agent Pools (Read) scope and 'Reader' on this pool, then re-run. Transient throttling/timeouts may also cause this." \
                '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
            echo "  WARNING: could not fetch agents for pool $pool_name ($pool_id): ${fetch_err:-unknown}"
            continue
        fi
        agents=$(load_pool_agents_json "$agents_file")

        eval "$(classify_pool_agents "$agents" "$is_elastic" "$pool_name")"
        agent_count=$AGENT_COUNT
        online_count=$ONLINE_COUNT
        offline_count=$OFFLINE_COUNT
        busy_count=$BUSY_COUNT
        pool_kind=$POOL_KIND

        echo "  Investigating pool: $pool_name [$pool_kind] ($online_count online / $offline_count offline / $agent_count total)"

        if [ "$pool_kind" = "elastic" ] || [ "$pool_kind" = "ephemeral" ]; then
            # Offline agents in elastic/ephemeral pools are torn-down scale-set
            # instances, not failures. A complete lack of online capacity is only
            # actionable when work is actually queued; idle scaled-to-zero is normal.
            if [ "$agent_count" -gt 0 ] && [ "$online_count" -eq 0 ]; then
                # Probe the job queue: aging queued work is the real outage signal,
                # not busy_assigned (which can't see jobs waiting with no agent).
                QUEUED_TOTAL=0; QUEUED_AGING=0; OLDEST_QUEUED_MIN=0
                if [ "${CHECK_QUEUE_ON_ZERO:-true}" = "true" ]; then
                    eval "$(pool_queue_pressure "$(load_pool_job_requests_json "$AGENT_CACHE_DIR/jobreqs_${pool_id}.json")" "${QUEUE_AGING_THRESHOLD_MIN:-15}")"
                fi
                queue_status="$(pool_queue_status_line "${busy_count:-0}" "$QUEUED_TOTAL" "$QUEUED_AGING" "$OLDEST_QUEUED_MIN")"

                # ESCALATION CONDITION (intent): sev 2 only for aging queued work,
                # sev 3 for work stuck on offline agents, else sev 4 advisory.
                if [ "$QUEUED_AGING" -gt 0 ]; then
                    pool_details=$(ado_pool_issue_details \
                        "Dynamic pool has 0 online agents AND $QUEUED_AGING queued build(s) aging past ${QUEUE_AGING_THRESHOLD_MIN:-15} min." \
                        "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                        "$offline_count" "$busy_count" "$offline_count" \
                        "Oldest queued job has waited ${OLDEST_QUEUED_MIN} min." "" \
                        "$POOL_KIND_REASON" "$queue_status")
                    investigation_json=$(echo "$investigation_json" | jq \
                        --arg title "Elastic Pool Has Queued Builds But No Online Agents: $pool_name" \
                        --arg details "$pool_details" \
                        --arg severity "2" \
                        --arg next_steps "Verify the VMSS/scale-set/Kubernetes scaler can provision agents: check the elastic pool sizing, the backing Azure scale set / KEDA health, the service connection, and any sizing errors in Organization Settings > Agent pools." \
                        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
                elif [ "${busy_count:-0}" -gt 0 ]; then
                    pool_details=$(ado_pool_issue_details \
                        "Dynamic pool has 0 online agents but $busy_count agent(s) still carry an assignedRequest." \
                        "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                        "$offline_count" "$busy_count" "$offline_count" \
                        "No queued work is aging; an assignedRequest on an offline agent is usually a stale scale-down record." "" \
                        "$POOL_KIND_REASON" "$queue_status")
                    investigation_json=$(echo "$investigation_json" | jq \
                        --arg title "Elastic Pool Has Work Assigned To Offline Agents: $pool_name" \
                        --arg details "$pool_details" \
                        --arg severity "3" \
                        --arg next_steps "Confirm the scaler replaced the torn-down agents. If the assignedRequest persists, re-queue the job or verify the backing VMSS/Kubernetes infrastructure." \
                        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
                else
                    # Expected idle autoscaling: cluster into ONE sev-4 advisory.
                    elastic_idle+=("\`$pool_name\` (id=$pool_id, $pool_kind): 0 online, $offline_count offline churn${queue_status:+; $queue_status}")
                fi
            fi
        elif [ "$offline_count" -gt 0 ]; then
            # Static pool: offline agents are lost capacity, but full outage
            # (0 online) vs reduced capacity (online>0) get different severity
            # when clustered below.
            offline_details=$(echo "$agents" | jq -r --argjson n "$MAX_OFFLINE_DETAIL" \
                '[.[] | select(.status == "offline")][:$n][] | .name' | paste -sd', ' -)
            if [ "$offline_count" -gt "$MAX_OFFLINE_DETAIL" ]; then
                offline_details="$offline_details, ... +$((offline_count - MAX_OFFLINE_DETAIL)) more"
            fi
            if [ "$online_count" -eq 0 ]; then
                static_offline+=("OUTAGE \`$pool_name\` (id=$pool_id): $offline_count of $agent_count offline, 0 online -- offline: $offline_details")
            else
                static_offline+=("REDUCED \`$pool_name\` (id=$pool_id): $offline_count of $agent_count offline, $online_count still online")
            fi
        fi

        # Outdated agents (applies to any non-hosted pool with persistent agents)
        outdated_count=$(echo "$agents" | jq '[.[] | select(.version != null and (.version | split(".")[0] | tonumber) < 2)] | length')
        if [ "$outdated_count" -gt 0 ]; then
            outdated_agents+=("\`$pool_name\` (id=$pool_id): $outdated_count agent(s) on a major version < 2")
        fi
    done

    # --- Clustered agent-pool findings (one issue per category, not per pool) ---
    if [ "${#static_offline[@]}" -gt 0 ]; then
        n_outage=$(printf '%s\n' "${static_offline[@]}" | grep -c '^OUTAGE ' || true)
        cluster_list=$(printf '  - %s\n' "${static_offline[@]}")
        sev=3; [ "${n_outage:-0}" -gt 0 ] && sev=2
        investigation_json=$(echo "$investigation_json" | jq \
            --arg title "Static Agent Pools With Offline Agents (${#static_offline[@]} pools, ${n_outage:-0} with no online capacity)" \
            --arg details "$( printf 'Self-hosted pools with offline agents (OUTAGE = 0 online; REDUCED = capacity remains):\n%s' "$cluster_list" )" \
            --arg severity "$sev" \
            --arg next_steps "For OUTAGE pools (highest priority): restart the offline agent services, confirm hosts are powered on and can reach dev.azure.com, and verify agent credentials/PAT. For REDUCED pools, restore agents at convenience. Delete retired pools so they stop being reported." \
            '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
    if [ "${#elastic_idle[@]}" -gt 0 ]; then
        cluster_list=$(printf '  - %s\n' "${elastic_idle[@]}")
        investigation_json=$(echo "$investigation_json" | jq \
            --arg title "Elastic Pools Scaled To Zero (Expected) (${#elastic_idle[@]} pools)" \
            --arg details "$( printf '%s elastic/ephemeral pool(s) are idle at 0 online agents with no queued work (expected autoscaling):\n%s' "${#elastic_idle[@]}" "$cluster_list" )" \
            --arg severity "4" \
            --arg next_steps "No action needed -- dynamic pools idle at 0 online agents are expected. If builds later queue without starting on any of these, investigate autoscale/VMSS/KEDA." \
            '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
    if [ "${#outdated_agents[@]}" -gt 0 ]; then
        cluster_list=$(printf '  - %s\n' "${outdated_agents[@]}")
        investigation_json=$(echo "$investigation_json" | jq \
            --arg title "Agent Pools Running Outdated Agent Versions (${#outdated_agents[@]} pools)" \
            --arg details "$( printf '%s pool(s) have agents on an outdated major version:\n%s' "${#outdated_agents[@]}" "$cluster_list" )" \
            --arg severity "2" \
            --arg next_steps "Update agent software to the latest version for security and compatibility." \
            '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    fi
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
    project_count=$(echo "$projects" | jq '.value | length')
    total_failures=0
    projects_with_failures=0
    
    # Check last 24 hours for failures
    from_date=$(date -d "24 hours ago" -u +"%Y-%m-%dT%H:%M:%SZ")
    
    for ((i=0; i<project_count && i<5; i++)); do  # Limit to first 5 projects for performance
        project_json=$(jq -c ".value[${i}]" <<< "$projects")
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
    project_count=$(echo "$projects" | jq '.value | length')
    for ((i=0; i<project_count && i<3; i++)); do  # Check first 3 projects
        project_json=$(jq -c ".value[${i}]" <<< "$projects")
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

# If no specific issues found, report healthy status to stdout only
if [ "$(echo "$investigation_json" | jq '. | length')" -eq 0 ]; then
    echo "Deep platform investigation completed - no specific issues identified for $AZURE_DEVOPS_ORG"
fi

# Write final JSON
echo "$investigation_json" > "$OUTPUT_FILE"
echo "Platform issue investigation completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== PLATFORM INVESTIGATION SUMMARY ==="
echo "$investigation_json" | jq -r '.[] | "Finding: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\nNext Steps: \(.next_steps)\n---"' 