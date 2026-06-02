#!/usr/bin/env bash
set -euo pipefail
# NOTE: `set -x` is intentionally NOT used (it leaks AZURE_DEVOPS_PAT into logs
# and bloats output). Set AZ_DEBUG=1 to opt in to tracing for local debugging.
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AUTH_TYPE (optional, default: service_principal)
#   AZURE_DEVOPS_PAT (required if AUTH_TYPE=pat)
#
# OPTIONAL ENV VARS:
#   MAX_PROJECTS   - cap on the number of projects scanned for shared resources
#                    (bounds runtime on large orgs; default 25)
#
# This script (Phase 0 single-pass refactor):
#   1) Lists projects and agent pools ONCE.
#   2) Makes a SINGLE bounded pass over projects (capped to MAX_PROJECTS),
#      fetching each project's pipelines and service connections exactly once,
#      and derives shared-pool / duplicate-connection / cross-project signals
#      from that. Previously it looped pools x projects (e.g. 473 x 168) issuing
#      `az pipelines list --project` inside BOTH the pool loop and again for
#      repos -- the volume wall that drove the 180s timeout.
#   3) Reports on resource sharing patterns.
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AUTH_TYPE:=service_principal}"
: "${MAX_PROJECTS:=25}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-$azure_devops_pat}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

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

# Setup authentication
if [ "$AUTH_TYPE" = "service_principal" ]; then
    echo "Using service principal authentication..."
    echo "Verifying Azure DevOps authentication..."
    for i in {1..3}; do
        if az devops project list --output none &>/dev/null; then
            echo "Authentication verified successfully"
            break
        else
            echo "Authentication not ready, waiting... (attempt $i/3)"
            sleep 2
        fi
        if [ $i -eq 3 ]; then
            echo "WARNING: Authentication verification failed, proceeding anyway..."
        fi
    done
elif [ "$AUTH_TYPE" = "pat" ]; then
    if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
        echo "ERROR: AZURE_DEVOPS_PAT must be set when AUTH_TYPE=pat"
        exit 1
    fi
    echo "Using PAT authentication..."
    echo "$AZURE_DEVOPS_PAT" | az devops login --organization "https://dev.azure.com/$AZURE_DEVOPS_ORG"
else
    echo "ERROR: Invalid AUTH_TYPE. Must be 'service_principal' or 'pat'"
    exit 1
fi

# Get list of projects (single call)
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
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
    echo "$dependencies_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f projects_err.log

echo "$projects" > projects.json
project_count=$(jq '.value | length' projects.json)

if [ "$project_count" -eq 0 ]; then
    echo "No projects found."
    dependencies_json='[{"title": "No Projects Found", "details": "No projects found in the organization", "severity": 2, "next_steps": "Verify project access permissions"}]'
    echo "$dependencies_json" > "$OUTPUT_FILE"
    rm -f projects.json
    exit 0
fi

# Bound the scan to keep runtime predictable on large orgs (168+ projects).
scan_count=$project_count
if [ "$scan_count" -gt "$MAX_PROJECTS" ]; then
    scan_count=$MAX_PROJECTS
fi
echo "Found $project_count projects. Analyzing dependencies across the first $scan_count (MAX_PROJECTS=$MAX_PROJECTS)..."

# Agent pools (single call) for the shared-pool denominator.
non_hosted_pools=()
if agent_pools=$(az pipelines pool list --output json 2>/dev/null); then
    while IFS= read -r pname; do
        [ -n "$pname" ] && non_hosted_pools+=("$pname")
    done < <(echo "$agent_pools" | jq -r '.[] | select((.isHosted // false) == false) | .name')
fi

# SINGLE bounded pass over projects: one pipelines call + one service-endpoint
# call per project, accumulating everything we need.
declare -A connection_projects
projects_with_pipelines=0
cross_repo_refs=0
analyzed=0

for ((i=0; i<scan_count; i++)); do
    project_name=$(jq -r ".value[${i}].name" projects.json)
    echo "  Scanning project: $project_name"
    analyzed=$((analyzed + 1))

    # Pipelines (one call). Used for shared-pool denominator + cross-repo heuristic.
    if pipelines=$(az pipelines list --project "$project_name" --output json 2>/dev/null); then
        pipeline_count=$(echo "$pipelines" | jq '. | length')
        if [ "$pipeline_count" -gt 0 ]; then
            projects_with_pipelines=$((projects_with_pipelines + 1))
        fi
        if [ "$pipeline_count" -gt 5 ]; then
            cross_repo_refs=$((cross_repo_refs + 1))
        fi
    fi

    # Service connections (one call). Used for duplicate-connection detection.
    if service_conns=$(az devops service-endpoint list --project "$project_name" --output json 2>/dev/null); then
        while IFS= read -r conn_name; do
            if [ -n "$conn_name" ]; then
                if [[ -v connection_projects["$conn_name"] ]]; then
                    connection_projects["$conn_name"]="${connection_projects["$conn_name"]},$project_name"
                else
                    connection_projects["$conn_name"]="$project_name"
                fi
            fi
        done < <(echo "$service_conns" | jq -r '.[].name')
    fi
done

# --- Shared agent pools ---------------------------------------------------
# A non-hosted pool is treated as shared when more than one analyzed project has
# pipelines (same approximation as before, now derived from the single pass).
shared_pools=()
if [ "$projects_with_pipelines" -gt 1 ]; then
    for pname in "${non_hosted_pools[@]}"; do
        shared_pools+=("$pname:$projects_with_pipelines")
    done
fi
if [ ${#shared_pools[@]} -gt 10 ]; then
    shared_pools_summary=$(IFS=', '; echo "${shared_pools[*]}")
    dependencies_json=$(echo "$dependencies_json" | jq \
        --arg title "Excessive Shared Agent Pools" \
        --arg details "Large number of agent pools (${#shared_pools[@]}) shared across projects: $shared_pools_summary" \
        --arg severity "3" \
        --arg next_steps "Review agent pool organization and consider consolidating or restructuring pools for better management" \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

# --- Duplicate service connections ----------------------------------------
duplicate_connections=()
for conn_name in "${!connection_projects[@]}"; do
    project_list="${connection_projects[$conn_name]}"
    project_count_for_conn=$(echo "$project_list" | tr ',' '\n' | wc -l)
    if [ "$project_count_for_conn" -gt 1 ]; then
        duplicate_connections+=("$conn_name")
    fi
done
if [ ${#duplicate_connections[@]} -gt 0 ]; then
    duplicate_summary=$(IFS=', '; echo "${duplicate_connections[*]}")
    dependencies_json=$(echo "$dependencies_json" | jq \
        --arg title "Duplicate Service Connections" \
        --arg details "Service connections with similar names across projects: $duplicate_summary" \
        --arg severity "2" \
        --arg next_steps "Review duplicate service connections and consider consolidating or using organization-level connections" \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

# --- Cross-project dependency heuristic -----------------------------------
if [ "$cross_repo_refs" -gt 0 ]; then
    dependencies_json=$(echo "$dependencies_json" | jq \
        --arg title "Potential Cross-Project Dependencies" \
        --arg details "$cross_repo_refs projects have complex pipeline configurations that may include cross-project dependencies" \
        --arg severity "4" \
        --arg next_steps "Review pipeline configurations for cross-project repository dependencies and ensure proper access controls" \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

# --- Similar project names (no API calls) ---------------------------------
similar_projects=()
for ((i=0; i<scan_count; i++)); do
    project_name=$(jq -r ".value[${i}].name" projects.json)
    for ((j=i+1; j<scan_count; j++)); do
        other_project_name=$(jq -r ".value[${j}].name" projects.json)
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
        --arg severity "4" \
        --arg next_steps "Review project organization and consider if projects should be consolidated or have clearer naming conventions" \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

if [ "$(echo "$dependencies_json" | jq '. | length')" -eq 0 ]; then
    echo "No significant cross-project dependency issues detected across $analyzed analyzed projects"
fi

# Clean up temporary files
rm -f projects.json

# Write final JSON
echo "$dependencies_json" > "$OUTPUT_FILE"
echo "Cross-project dependencies analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== CROSS-PROJECT DEPENDENCIES SUMMARY ==="
echo "Projects in Org: $project_count (analyzed: $analyzed)"
echo "Shared Agent Pools: ${#shared_pools[@]}"
echo "Duplicate Service Connections: ${#duplicate_connections[@]}"
echo ""
echo "$dependencies_json" | jq -r '.[] | "Finding: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"'
