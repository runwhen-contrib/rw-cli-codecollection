#!/usr/bin/env bash
# Preflight access check (capability probe).
#
# Rather than trying to enumerate every group membership (which requires the
# Graph scope that many otherwise-valid PATs lack), this probes each capability
# the codebundle actually uses with a cheap, read-only `az` call and reports:
#   - whether the identity CAN perform it (OK / DENIED / ERROR), and
#   - the exact PAT scope and Azure DevOps role required when it cannot.
#
# Using `az` (not raw curl) means the probe shares the same authentication and
# network/proxy path as the rest of the tasks, so its result actually reflects
# what those tasks will experience.
#
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECTS  - comma-separated project names to validate
#
# Writes preflight_results.json (identity, per-capability results, summary).

set -uo pipefail
[ "${AZ_DEBUG:-0}" = "1" ] && set -x

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECTS:?Must set AZURE_DEVOPS_PROJECTS}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="preflight_results.json"
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"

setup_azure_auth

# First project is used as a representative target for project-scoped probes.
IFS=',' read -ra PROJECTS <<< "$AZURE_DEVOPS_PROJECTS"
PRIMARY_PROJECT=""
for p in "${PROJECTS[@]}"; do
    p=$(echo "$p" | xargs)
    if [ -n "$p" ]; then PRIMARY_PROJECT="$p"; break; fi
done

capabilities='[]'
blocking=0

# Classify the outcome of an az command.
#   $1 = capability name (human readable)
#   $2 = required PAT scope
#   $3 = required Azure DevOps role
#   $4 = "core" or "optional" (core failures block the run)
#   $5.. = the command to run
probe() {
    local name="$1" scope="$2" role="$3" tier="$4"; shift 4
    local err status detail
    err=$("$@" 2>&1 >/dev/null)
    local rc=$?

    if [ $rc -eq 0 ]; then
        status="OK"; detail="Accessible."
        echo "  [OK]     $name"
    else
        local lc; lc=$(echo "$err" | tr '[:upper:]' '[:lower:]')
        if echo "$lc" | grep -Eq 'denied|not authorized|forbidden|do not have|tf400813|403|unauthorized|401'; then
            status="DENIED"
        elif echo "$lc" | grep -Eq 'timed out|timeout|could not resolve|connection|network|unreachable'; then
            status="NETWORK"
        else
            status="ERROR"
        fi
        detail=$(echo "$err" | head -c 300 | tr '\n' ' ')
        [ "$tier" = "core" ] && blocking=$((blocking + 1))
        echo "  [$status] $name -> needs PAT scope '$scope' / role '$role'"
    fi

    capabilities=$(echo "$capabilities" | jq \
        --arg name "$name" --arg scope "$scope" --arg role "$role" \
        --arg tier "$tier" --arg status "$status" --arg detail "$detail" \
        '. += [{capability:$name, status:$status, tier:$tier, required_pat_scope:$scope, required_role:$role, detail:$detail}]')
}

# =========================================================================
# 1. Identity (best effort, non-blocking)
# =========================================================================
echo "=== Authenticated Identity ==="
identity_json=$(ado_identity_json)
if [ "$(echo "$identity_json" | jq -r '.confirmed')" = "true" ]; then
    echo "  Display Name: $(echo "$identity_json" | jq -r '.name')"
    echo "  User ID:      $(echo "$identity_json" | jq -r '.id')"
    [ -n "$(echo "$identity_json" | jq -r '.email')" ] && echo "  Account:      $(echo "$identity_json" | jq -r '.email')"
else
    echo "  NOTE: could not resolve the authenticated identity (connectionData blocked"
    echo "        by a proxy, or a PAT without Graph scope). Non-blocking; the capability"
    echo "        probes below are the authoritative access signal."
fi

# =========================================================================
# 2. Capability probes (authoritative)
# =========================================================================
echo ""
echo "=== Capability Probes ==="
probe "Projects (read)" "vso.project (Project and Team: Read)" \
    "Project-level Reader (or member of Project Valid Users)" "core" \
    az devops project list --org "$ORG_URL" --top 1 --output json

probe "Agent Pools (read)" "vso.agentpools (Agent Pools: Read)" \
    "Reader on Organization Settings > Agent pools" "core" \
    az pipelines pool list --org "$ORG_URL" --output json

if [ -n "$PRIMARY_PROJECT" ]; then
    probe "Pipelines/Builds (read) [$PRIMARY_PROJECT]" "vso.build (Build: Read)" \
        "Build Reader (Readers group) on the project" "core" \
        az pipelines build list --project "$PRIMARY_PROJECT" --org "$ORG_URL" --top 1 --output json

    probe "Repositories (read) [$PRIMARY_PROJECT]" "vso.code (Code: Read)" \
        "Reader/Contributor on the project's repositories" "core" \
        az repos list --project "$PRIMARY_PROJECT" --org "$ORG_URL" --output json

    probe "Service Connections (read) [$PRIMARY_PROJECT]" "vso.serviceendpoint (Service Connections: Read)" \
        "Reader on the project's service connections" "optional" \
        az devops service-endpoint list --project "$PRIMARY_PROJECT" --org "$ORG_URL" --output json
fi

# =========================================================================
# 3. Summary
# =========================================================================
echo ""
echo "=== Preflight Summary ==="

total=$(echo "$capabilities" | jq 'length')
ok=$(echo "$capabilities" | jq '[.[] | select(.status=="OK")] | length')
identity_name=$(echo "$identity_json" | jq -r '.name')
optional_missing=$(echo "$capabilities" | jq -r '[.[] | select(.status!="OK" and .tier=="optional") | "\(.capability) (needs \(.required_pat_scope) / \(.required_role))"] | join("; ")')

if [ "$blocking" -eq 0 ]; then
    access_ok=true
    if [ -n "$optional_missing" ]; then
        summary="Access OK for core tasks ($ok/$total capabilities) as identity '${identity_name}'. Limited: ${optional_missing} — related tasks will be partial until granted."
    else
        summary="Access OK: identity '${identity_name}' can perform all required Azure DevOps reads ($ok/$total capabilities). Project health tasks should run normally."
    fi
else
    access_ok=false
    missing=$(echo "$capabilities" | jq -r '[.[] | select(.status!="OK" and .tier=="core") | "\(.capability) (needs \(.required_pat_scope) / \(.required_role))"] | join("; ")')
    summary="INSUFFICIENT ACCESS: identity '${identity_name}' is missing $blocking required capability(ies): ${missing}. Grant the listed PAT scopes/roles and re-run; affected tasks will return empty or partial results until then."
fi

echo "$summary"

result_json=$(jq -n \
    --arg org "$AZURE_DEVOPS_ORG" \
    --argjson identity "$identity_json" \
    --argjson capabilities "$capabilities" \
    --argjson access_ok "$access_ok" \
    --arg summary "$summary" \
    '{organization:$org, identity:$identity, capabilities:$capabilities, access_ok:$access_ok, summary:$summary}')

echo "$result_json" > "$OUTPUT_FILE"
echo "Results saved to $OUTPUT_FILE"
