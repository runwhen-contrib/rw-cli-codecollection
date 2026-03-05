#!/usr/bin/env bash
# Preflight check: identifies the authenticated identity and enumerates
# actual group memberships (roles) using the Azure DevOps REST API.
#
# Instead of "try an API and see if it works", this lists the concrete
# roles the identity holds -- which is defensible and actionable when
# troubleshooting permission issues.
#
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECTS  - comma-separated project names to validate
#
# Outputs preflight_results.json with identity, group memberships, and
# per-project role summary.

set -uo pipefail

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECTS:?Must set AZURE_DEVOPS_PROJECTS}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-$azure_devops_pat}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="preflight_results.json"
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"
VSSPS_URL="https://vssps.dev.azure.com/$AZURE_DEVOPS_ORG"

setup_azure_auth

build_auth_header() {
    if [ "$AUTH_TYPE" = "pat" ]; then
        printf "Basic %s" "$(printf ':%s' "$AZURE_DEVOPS_EXT_PAT" | base64 -w0)"
    else
        local token
        token=$(az account get-access-token \
            --resource 499b84ac-1321-427f-aa17-267ca6975798 \
            --query accessToken -o tsv 2>/dev/null || echo "")
        if [ -n "$token" ]; then
            printf "Bearer %s" "$token"
        fi
    fi
}

AUTH_HEADER=$(build_auth_header)

api_get() {
    if [ -n "$AUTH_HEADER" ]; then
        curl -s --max-time 15 -H "Authorization: $AUTH_HEADER" "$1"
    else
        echo '{"error": "no auth header available"}'
    fi
}

# =========================================================================
# 1. Identify the authenticated user via _apis/connectionData
# =========================================================================
echo "=== Authenticated Identity ==="
identity_json='{"name":"unknown","id":"unknown","auth_type":"'"$AUTH_TYPE"'","error":"not retrieved"}'
subject_descriptor=""

conn_data=$(api_get "$ORG_URL/_apis/connectionData?api-version=7.1")

if echo "$conn_data" | jq -e '.authenticatedUser' &>/dev/null; then
    user_display=$(echo "$conn_data" | jq -r '.authenticatedUser.providerDisplayName // "unknown"')
    user_id=$(echo "$conn_data" | jq -r '.authenticatedUser.id // "unknown"')
    subject_descriptor=$(echo "$conn_data" | jq -r '.authenticatedUser.subjectDescriptor // empty')

    echo "  Display Name:  $user_display"
    echo "  User ID:       $user_id"
    echo "  Auth Type:     $AUTH_TYPE"

    identity_json=$(jq -n \
        --arg name "$user_display" \
        --arg id "$user_id" \
        --arg descriptor "${subject_descriptor:-}" \
        --arg auth_type "$AUTH_TYPE" \
        '{name: $name, id: $id, descriptor: $descriptor, auth_type: $auth_type}')
else
    echo "  ERROR: Could not retrieve identity via connectionData API"
    echo "  Hint:  Verify the PAT or service principal credentials are valid."
    if echo "$conn_data" | jq -e '.message' &>/dev/null; then
        api_msg=$(echo "$conn_data" | jq -r '.message' | head -c 300)
        echo "  API message: $api_msg"
    fi
fi

# =========================================================================
# 2. Enumerate group memberships via Graph API
# =========================================================================
echo ""
echo "=== Group Memberships ==="
all_groups='[]'

if [ -n "$subject_descriptor" ]; then
    membership_response=$(api_get "$VSSPS_URL/_apis/graph/memberships/$subject_descriptor?direction=up&api-version=7.1-preview.1")

    if echo "$membership_response" | jq -e '.value' &>/dev/null; then
        member_count=$(echo "$membership_response" | jq '.value | length')
        echo "  Resolving $member_count group membership(s)..."
        echo ""

        while IFS= read -r desc; do
            [ -z "$desc" ] && continue
            group_info=$(api_get "$VSSPS_URL/_apis/graph/groups/$desc?api-version=7.1-preview.1")

            if echo "$group_info" | jq -e '.principalName' &>/dev/null; then
                principal=$(echo "$group_info" | jq -r '.principalName // "unknown"')
                display=$(echo "$group_info" | jq -r '.displayName // "unknown"')
                scope_field=$(echo "$group_info" | jq -r '.domain // "unknown"')

                echo "  - $principal"

                all_groups=$(echo "$all_groups" | jq \
                    --arg p "$principal" \
                    --arg d "$display" \
                    --arg s "$scope_field" \
                    '. += [{"principalName": $p, "displayName": $d, "scope": $s}]')
            fi
        done < <(echo "$membership_response" | jq -r '.value[].containerDescriptor // empty')

        echo ""
        echo "  Total: $(echo "$all_groups" | jq 'length') group(s)"
    else
        echo "  WARNING: Could not list memberships via Graph API."
        echo "  The PAT may lack the Graph (Read) or Member Entitlement Management (Read) scope."
        if echo "$membership_response" | jq -e '.message' &>/dev/null; then
            api_msg=$(echo "$membership_response" | jq -r '.message' | head -c 300)
            echo "  API message: $api_msg"
        fi
    fi
else
    echo "  SKIPPED: No identity descriptor available -- cannot enumerate memberships."
    echo "  This typically means the connectionData call above failed."
fi

# =========================================================================
# 3. Per-project role summary
# =========================================================================
echo ""
echo "=== Per-Project Role Summary ==="
project_roles='[]'

IFS=',' read -ra PROJECTS <<< "$AZURE_DEVOPS_PROJECTS"
for project in "${PROJECTS[@]}"; do
    project=$(echo "$project" | xargs)
    [ -z "$project" ] && continue

    echo "  Project: $project"

    proj_prefix="[$project]\\"
    proj_groups=$(echo "$all_groups" | jq --arg p "$proj_prefix" \
        '[.[] | select(.principalName | startswith($p)) | .displayName]')
    count=$(echo "$proj_groups" | jq 'length')

    if [ "$count" -gt 0 ]; then
        echo "$proj_groups" | jq -r '.[] | "    Role: " + .'
    else
        echo "    WARNING: No project-level roles found for this identity."
        echo "    The identity may not be a direct member of project '$project',"
        echo "    or group membership enumeration was not possible."
    fi

    project_roles=$(echo "$project_roles" | jq \
        --arg proj "$project" \
        --argjson groups "$proj_groups" \
        '. += [{"project": $proj, "roles": $groups, "role_count": ($groups | length)}]')
done

# Org-level roles
echo ""
echo "  Organization-level roles:"
org_prefix="[$AZURE_DEVOPS_ORG]\\"
org_roles=$(echo "$all_groups" | jq --arg o "$org_prefix" \
    '[.[] | select(.principalName | startswith($o)) | .displayName]')
org_count=$(echo "$org_roles" | jq 'length')

if [ "$org_count" -gt 0 ]; then
    echo "$org_roles" | jq -r '.[] | "    Role: " + .'
else
    echo "    (none found)"
fi

# =========================================================================
# 4. Build summary
# =========================================================================
echo ""
echo "=== Preflight Summary ==="

total_groups=$(echo "$all_groups" | jq 'length')
projects_with_roles=$(echo "$project_roles" | jq '[.[] | select(.role_count > 0)] | length')
total_projects=$(echo "$project_roles" | jq 'length')
user_name=$(echo "$identity_json" | jq -r '.name')

if [ "$total_groups" -eq 0 ] && [ -n "$subject_descriptor" ]; then
    summary="WARNING: Identity '$user_name' authenticated successfully but has 0 group memberships. Check Graph API scope on the PAT."
elif [ "$total_groups" -eq 0 ]; then
    summary="ERROR: Could not identify the authenticated user or enumerate permissions. Check credentials."
elif [ "$projects_with_roles" -lt "$total_projects" ]; then
    missing=$(echo "$project_roles" | jq -r '[.[] | select(.role_count == 0) | .project] | join(", ")')
    summary="WARNING: Identity '$user_name' has $total_groups group(s) but no project-level roles in: $missing. These projects may produce incomplete results."
else
    role_details=""
    for project in "${PROJECTS[@]}"; do
        project=$(echo "$project" | xargs)
        [ -z "$project" ] && continue
        roles=$(echo "$project_roles" | jq -r --arg p "$project" '.[] | select(.project == $p) | .roles | join(", ")')
        role_details="${role_details}${project}: ${roles}; "
    done
    summary="Identity '$user_name' has $total_groups group(s). Project roles: ${role_details% ; }"
fi

echo "$summary"

# =========================================================================
# 5. Write JSON output
# =========================================================================
result_json=$(jq -n \
    --arg org "$AZURE_DEVOPS_ORG" \
    --argjson identity "$identity_json" \
    --argjson memberships "$all_groups" \
    --argjson project_roles "$project_roles" \
    --argjson org_roles "$org_roles" \
    --arg summary "$summary" \
    '{
        organization: $org,
        identity: $identity,
        memberships: $memberships,
        project_roles: $project_roles,
        org_level_roles: $org_roles,
        summary: $summary
    }')

echo "$result_json" > "$OUTPUT_FILE"
echo "Results saved to $OUTPUT_FILE"
