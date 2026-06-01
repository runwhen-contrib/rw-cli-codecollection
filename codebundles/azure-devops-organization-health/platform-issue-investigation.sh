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
#
# This script:
#   1) Performs deep investigation of platform-wide issues
#   2) Detects elastic/VMSS pools so transient offline agents are not flagged
#   3) Correlates issues across different services
#   4) Suggests remediation steps
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AUTH_TYPE:=service_principal}"
: "${MAX_OFFLINE_DETAIL:=20}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="platform_issue_investigation.json"
investigation_json='[]'
AGENT_CACHE_DIR="$(mktemp -d platforminv.XXXXXX)"
trap 'rm -rf "$AGENT_CACHE_DIR"' EXIT

echo "Deep Platform Issue Investigation..."
echo "Organization: $AZURE_DEVOPS_ORG"

setup_azure_auth

# Investigate agent pool issues in detail
echo "Detecting elastic (VMSS/scale-set) agent pools..."
load_elastic_pool_ids

echo "Investigating agent pool issues..."
if agent_pools=$(az pipelines pool list --output json 2>/dev/null); then
    pool_count=$(echo "$agent_pools" | jq '. | length')

    # Fetch all pool agents in parallel rather than one slow call per pool.
    echo "  Fetching agents for $pool_count pools (parallelism: ${AGENT_FETCH_PARALLELISM:-20})..."
    fetch_pool_agents_parallel "$agent_pools" "$AGENT_CACHE_DIR"

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
            if [ "$agent_count" -gt 0 ] && [ "$online_count" -eq 0 ] && [ "${busy_count:-0}" -gt 0 ]; then
                pool_details=$(ado_pool_issue_details \
                    "Elastic/ephemeral pool has 0 online agents but active assignedRequest on $busy_count agent(s)." \
                    "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                    "$offline_count" "$busy_count" "$offline_count" "" "")
                investigation_json=$(echo "$investigation_json" | jq \
                    --arg title "Elastic Pool Has No Online Agents While Work Is Assigned: $pool_name" \
                    --arg details "$pool_details" \
                    --arg severity "2" \
                    --arg next_steps "Verify the VMSS/scale-set/Kubernetes scaler can provision agents: check the elastic pool configuration, the backing Azure scale set / KEDA health, the service connection, and any sizing errors in Azure DevOps > Organization Settings > Agent pools." \
                    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
            elif [ "$agent_count" -gt 0 ] && [ "$online_count" -eq 0 ]; then
                pool_details=$(ado_pool_issue_details \
                    "Pool scaled to zero with $offline_count expected offline registrations; no assignedRequest detected." \
                    "$pool_name" "$pool_id" "$pool_type" "$pool_kind" "$agent_count" "$online_count" \
                    "$offline_count" "$busy_count" "$offline_count" \
                    "Advisory: verify whether pipeline runs are queued for this pool in Azure DevOps." "")
                investigation_json=$(echo "$investigation_json" | jq \
                    --arg title "Elastic Pool Scaled To Zero (Verify Queue): $pool_name" \
                    --arg details "$pool_details" \
                    --arg severity "4" \
                    --arg next_steps "No action if no pipelines are waiting. If builds are queued, investigate autoscale/VMSS/KEDA." \
                    '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
            fi
        elif [ "$offline_count" -gt 0 ]; then
            # Static pool: offline agents are genuine lost capacity. Cap the
            # enumerated detail to avoid pathological output sizes.
            offline_details=$(echo "$agents" | jq -r --argjson n "$MAX_OFFLINE_DETAIL" \
                '[.[] | select(.status == "offline")][:$n][] | "Agent: \(.name), Version: \(.version // "unknown"), Last Contact: \(.statusChangedOn // "unknown")"' \
                | paste -sd'; ' -)
            if [ "$offline_count" -gt "$MAX_OFFLINE_DETAIL" ]; then
                offline_details="$offline_details; ... and $((offline_count - MAX_OFFLINE_DETAIL)) more"
            fi

            pool_details=$(ado_pool_issue_details \
                "Static pool has $offline_count offline agents out of $agent_count total." \
                "$pool_name" "$pool_id" "${pool_type:-unknown}" "$pool_kind" "$agent_count" "$online_count" \
                "$offline_count" "$busy_count" "0" "" "$offline_details")
            investigation_json=$(echo "$investigation_json" | jq \
                --arg title "Offline Agents in Pool: $pool_name" \
                --arg details "$pool_details" \
                --arg severity "3" \
                --arg next_steps "Check agent connectivity, restart agent services, and verify network connectivity for offline agents" \
                '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
        fi

        # Outdated agents (applies to any non-hosted pool with persistent agents)
        outdated_count=$(echo "$agents" | jq '[.[] | select(.version != null and (.version | split(".")[0] | tonumber) < 2)] | length')
        if [ "$outdated_count" -gt 0 ]; then
            investigation_json=$(echo "$investigation_json" | jq \
                --arg title "Outdated Agents in Pool: $pool_name" \
                --arg details "Pool $pool_name has $outdated_count agents running outdated versions" \
                --arg severity "2" \
                --arg next_steps "Update agent software to latest version for security and compatibility" \
                '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
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