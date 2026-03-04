#!/usr/bin/env bash
# Preflight check: validates identity, API connectivity, and per-scope access
# for each project before the main health checks run.
#
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECTS  - comma-separated project names to validate
#
# Outputs preflight_results.json with identity info and per-scope access results.

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECTS:?Must set AZURE_DEVOPS_PROJECTS}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-$azure_devops_pat}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="preflight_results.json"
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"

setup_azure_auth

# --- Identity info ---
echo "=== Identifying logged-in account ==="
identity_json='{}'

if account_info=$(az account show --output json 2>/dev/null); then
    identity_name=$(echo "$account_info" | jq -r '.user.name // "unknown"')
    identity_type=$(echo "$account_info" | jq -r '.user.type // "unknown"')
    subscription=$(echo "$account_info" | jq -r '.name // "unknown"')
    tenant_id=$(echo "$account_info" | jq -r '.tenantId // "unknown"')

    identity_json=$(jq -n \
        --arg name "$identity_name" \
        --arg type "$identity_type" \
        --arg subscription "$subscription" \
        --arg tenant "$tenant_id" \
        --arg auth_type "$AUTH_TYPE" \
        '{name: $name, type: $type, subscription: $subscription, tenant: $tenant, auth_type: $auth_type}')

    echo "  Identity: $identity_name ($identity_type)"
    echo "  Auth:     $AUTH_TYPE"
    echo "  Tenant:   $tenant_id"
else
    echo "  WARNING: Could not retrieve account info"
    identity_json=$(jq -n --arg auth_type "$AUTH_TYPE" '{name: "unknown", type: "unknown", auth_type: $auth_type, error: "Could not retrieve account info"}')
fi

# --- Organization-level access ---
echo ""
echo "=== Testing organization-level access ==="
org_access='{}'

echo -n "  Agent pools: "
if timeout 15 az pipelines pool list --org "$ORG_URL" --top 1 --output json &>/dev/null; then
    echo "OK"
    org_access=$(echo "$org_access" | jq '. + {agent_pools: "ok"}')
else
    echo "DENIED/FAILED"
    org_access=$(echo "$org_access" | jq '. + {agent_pools: "denied_or_failed"}')
fi

# --- Per-project access checks ---
echo ""
echo "=== Testing per-project access ==="
project_results='[]'

IFS=',' read -ra PROJECTS <<< "$AZURE_DEVOPS_PROJECTS"
for project in "${PROJECTS[@]}"; do
    project=$(echo "$project" | xargs)  # trim whitespace
    [ -z "$project" ] && continue

    echo "  Project: $project"
    proj_result=$(jq -n --arg name "$project" '{project: $name}')

    # Project access
    echo -n "    project show:         "
    if timeout 15 az devops project show --project "$project" --org "$ORG_URL" --output json &>/dev/null; then
        echo "OK"
        proj_result=$(echo "$proj_result" | jq '. + {project_access: "ok"}')
    else
        echo "DENIED/FAILED"
        proj_result=$(echo "$proj_result" | jq '. + {project_access: "denied_or_failed"}')
    fi

    # Pipelines read
    echo -n "    pipelines list:       "
    if timeout 15 az pipelines list --project "$project" --org "$ORG_URL" --top 1 --output json &>/dev/null; then
        echo "OK"
        proj_result=$(echo "$proj_result" | jq '. + {pipelines: "ok"}')
    else
        echo "DENIED/FAILED"
        proj_result=$(echo "$proj_result" | jq '. + {pipelines: "denied_or_failed"}')
    fi

    # Pipeline runs read
    echo -n "    pipeline runs list:   "
    if timeout 15 az pipelines runs list --project "$project" --org "$ORG_URL" --top 1 --output json &>/dev/null; then
        echo "OK"
        proj_result=$(echo "$proj_result" | jq '. + {pipeline_runs: "ok"}')
    else
        echo "DENIED/FAILED"
        proj_result=$(echo "$proj_result" | jq '. + {pipeline_runs: "denied_or_failed"}')
    fi

    # Repos read
    echo -n "    repos list:           "
    if timeout 15 az repos list --project "$project" --org "$ORG_URL" --top 1 --output json &>/dev/null; then
        echo "OK"
        proj_result=$(echo "$proj_result" | jq '. + {repos: "ok"}')
    else
        echo "DENIED/FAILED"
        proj_result=$(echo "$proj_result" | jq '. + {repos: "denied_or_failed"}')
    fi

    # Service endpoints read
    echo -n "    service endpoints:    "
    if timeout 15 az devops service-endpoint list --project "$project" --org "$ORG_URL" --output json &>/dev/null; then
        echo "OK"
        proj_result=$(echo "$proj_result" | jq '. + {service_endpoints: "ok"}')
    else
        echo "DENIED/FAILED"
        proj_result=$(echo "$proj_result" | jq '. + {service_endpoints: "denied_or_failed"}')
    fi

    # Repo policies read
    echo -n "    repo policies:        "
    if timeout 15 az repos policy list --project "$project" --org "$ORG_URL" --output json &>/dev/null; then
        echo "OK"
        proj_result=$(echo "$proj_result" | jq '. + {repo_policies: "ok"}')
    else
        echo "DENIED/FAILED"
        proj_result=$(echo "$proj_result" | jq '. + {repo_policies: "denied_or_failed"}')
    fi

    project_results=$(echo "$project_results" | jq --argjson proj "$proj_result" '. += [$proj]')
done

# --- Build summary ---
denied_count=$(echo "$project_results" | jq '[.[] | to_entries[] | select(.value == "denied_or_failed" and .key != "project")] | length')
org_denied=$(echo "$org_access" | jq '[to_entries[] | select(.value == "denied_or_failed")] | length')
total_denied=$((denied_count + org_denied))

if [ "$total_denied" -gt 0 ]; then
    summary="WARNING: $total_denied API scope(s) returned denied or failed. Some health checks may produce incomplete results."
else
    summary="All API scopes accessible. Preflight checks passed."
fi

# --- Write output ---
result_json=$(jq -n \
    --argjson identity "$identity_json" \
    --argjson org_access "$org_access" \
    --argjson projects "$project_results" \
    --arg summary "$summary" \
    --arg org "$AZURE_DEVOPS_ORG" \
    '{
        organization: $org,
        identity: $identity,
        org_level_access: $org_access,
        project_access: $projects,
        summary: $summary
    }')

echo "$result_json" > "$OUTPUT_FILE"

echo ""
echo "=== Preflight Summary ==="
echo "$summary"
echo "Results saved to $OUTPUT_FILE"
