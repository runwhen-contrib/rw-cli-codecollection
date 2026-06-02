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
#   $5 = REST endpoint actually exercised (for the report, e.g. "GET /_apis/projects")
#   $6.. = the command to run
probe() {
    local name="$1" scope="$2" role="$3" tier="$4" endpoint="$5"; shift 5
    local err status detail http_status=""
    err=$("$@" 2>&1 >/dev/null)
    local rc=$?

    if [ $rc -eq 0 ]; then
        status="OK"; detail="Accessible."
        printf '  [OK]      %-42s %s\n' "$name" "$endpoint"
    else
        local lc; lc=$(echo "$err" | tr '[:upper:]' '[:lower:]')
        # Extract a concrete HTTP status when present so the report can say
        # exactly what the API returned. Prefer the numeric HTTP code; any
        # TF###### code stays visible in the captured detail string below.
        http_status=$(printf '%s' "$err" | grep -oiE '\b(401|403|404|409|429|500|502|503)\b' | head -n1)
        if echo "$lc" | grep -Eq 'denied|not authorized|forbidden|do not have|tf400813|403|unauthorized|401'; then
            status="DENIED"
            [ -z "$http_status" ] && http_status="403"
        elif echo "$lc" | grep -Eq 'timed out|timeout|could not resolve|connection|network|unreachable'; then
            status="NETWORK"
        else
            status="ERROR"
        fi
        detail=$(echo "$err" | head -c 300 | tr '\n' ' ')
        [ "$tier" = "core" ] && blocking=$((blocking + 1))
        local httptxt=""; [ -n "$http_status" ] && httptxt=" (HTTP ${http_status})"
        printf '  [%-7s] %-42s %s%s\n' "$status" "$name" "$endpoint" "$httptxt"
        printf '            -> needs PAT scope %s / role %s\n' "$scope" "$role"
    fi

    capabilities=$(echo "$capabilities" | jq \
        --arg name "$name" --arg scope "$scope" --arg role "$role" \
        --arg tier "$tier" --arg status "$status" --arg detail "$detail" \
        --arg endpoint "$endpoint" --arg http "$http_status" \
        '. += [{capability:$name, status:$status, tier:$tier, required_pat_scope:$scope, required_role:$role, endpoint:$endpoint, http_status:$http, detail:$detail}]')
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
    "GET /_apis/projects" \
    az devops project list --org "$ORG_URL" --top 1 --output json

probe "Agent Pools (read)" "vso.agentpools (Agent Pools: Read)" \
    "Reader on Organization Settings > Agent pools" "core" \
    "GET /_apis/distributedtask/pools" \
    az pipelines pool list --org "$ORG_URL" --output json

if [ -n "$PRIMARY_PROJECT" ]; then
    probe "Pipelines/Builds (read) [$PRIMARY_PROJECT]" "vso.build (Build: Read)" \
        "Build Reader (Readers group) on the project" "core" \
        "GET /{project}/_apis/build/builds" \
        az pipelines build list --project "$PRIMARY_PROJECT" --org "$ORG_URL" --top 1 --output json

    probe "Repositories (read) [$PRIMARY_PROJECT]" "vso.code (Code: Read)" \
        "Reader/Contributor on the project's repositories" "core" \
        "GET /{project}/_apis/git/repositories" \
        az repos list --project "$PRIMARY_PROJECT" --org "$ORG_URL" --output json

    probe "Service Connections (read) [$PRIMARY_PROJECT]" "vso.serviceendpoint (Service Connections: Read)" \
        "Reader on the project's service connections" "optional" \
        "GET /{project}/_apis/serviceendpoint/endpoints" \
        az devops service-endpoint list --project "$PRIMARY_PROJECT" --org "$ORG_URL" --output json
fi

# =========================================================================
# 3. Summary
# =========================================================================
echo ""
echo "=== Preflight Summary ==="

# Guard: ado_identity_json should always return a JSON object, but a transient
# failure (or an older helper) could echo an empty string, which would make the
# final `jq -n --argjson identity ""` abort and leave preflight_results.json
# missing/empty — the exact bug that made a fully-accessible run report
# "Insufficient Azure DevOps Access" with no detail. Never trust it blindly.
if ! echo "$identity_json" | jq -e . >/dev/null 2>&1; then
    identity_json='{"name":"unknown","id":"unknown","email":"","auth_type":"'"${AUTH_TYPE:-service_principal}"'","confirmed":false}'
fi

case "${AUTH_TYPE:-service_principal}" in
    pat) auth_mode="Personal Access Token (PAT)" ;;
    *)   auth_mode="Service Principal" ;;
esac

total=$(echo "$capabilities" | jq 'length')
ok=$(echo "$capabilities" | jq '[.[] | select(.status=="OK")] | length')
identity_confirmed=$(echo "$identity_json" | jq -r '.confirmed // false')
identity_name=$(echo "$identity_json" | jq -r '.name // "unknown"')
if [ "$identity_confirmed" = "true" ]; then
    identity_line="${identity_name} (id=$(echo "$identity_json" | jq -r '.id // "unknown"'))"
else
    identity_line="could not be resolved (connectionData blocked by proxy or PAT lacks vso.profile) — capability probes below are authoritative"
fi
optional_missing=$(echo "$capabilities" | jq -r '[.[] | select(.status!="OK" and .tier=="optional") | "\(.capability) (needs \(.required_pat_scope) / \(.required_role))"] | join("; ")')

if [ "$blocking" -eq 0 ]; then
    access_ok=true
    if [ -n "$optional_missing" ]; then
        summary="Access OK for core tasks ($ok/$total capabilities) via ${auth_mode} as identity '${identity_name}'. Limited: ${optional_missing} — related tasks will be partial until granted."
    else
        summary="Access OK: identity '${identity_name}' (${auth_mode}) can perform all required Azure DevOps reads ($ok/$total capabilities). Project health tasks should run normally."
    fi
else
    access_ok=false
    missing=$(echo "$capabilities" | jq -r '[.[] | select(.status!="OK" and .tier=="core") | "\(.capability) (needs \(.required_pat_scope) / \(.required_role))"] | join("; ")')
    summary="INSUFFICIENT ACCESS: identity '${identity_name}' (${auth_mode}) is missing $blocking required capability(ies): ${missing}. Grant the listed PAT scopes/roles and re-run; affected tasks will return empty or partial results until then."
fi

echo "$summary"

# Build a single, self-contained, actionable report block. This is what the
# runbook drops verbatim into the issue_details so a human or a troubleshooting
# agent sees EXACTLY which capability failed, on which endpoint, with what
# status, and precisely what scope/role to grant — without needing the raw log.
report=$(echo "$capabilities" | jq -r \
    --arg org "$AZURE_DEVOPS_ORG" \
    --arg auth "$auth_mode" \
    --arg ident "$identity_line" \
    --arg summary "$summary" '
    [
      "Azure DevOps preflight access check",
      "Organization : \($org)",
      "Auth mode    : \($auth)",
      "Identity     : \($ident)",
      "Result       : \($summary)",
      "",
      "Capability matrix (capability -> endpoint -> result):"
    ]
    + [ .[] | "  [\(.status)] \(.capability)  ->  \(.endpoint)" + (if (.http_status // "") != "" then "  (HTTP \(.http_status))" else "" end) ]
    + (
        [ .[] | select(.status != "OK") ] as $bad
        | if ($bad | length) == 0 then []
          else
            ["", "How to grant the missing access:"]
            + ( $bad | to_entries | map(
                "  \(.key + 1). \(.value.capability) [\(.value.tier)] returned \(.value.status)\(if (.value.http_status // "") != "" then " (HTTP \(.value.http_status))" else "" end) on \(.value.endpoint)."
                + "\n       - Add PAT scope: \(.value.required_pat_scope)  (User settings > Personal access tokens > Edit > Scopes)."
                + "\n       - Ensure role : \(.value.required_role)."
                + (if (.value.detail // "") != "" and .value.detail != "Accessible." then "\n       - API said    : \(.value.detail)" else "" end)
              ))
          end
      )
    | join("\n")')

result_json=$(jq -n \
    --arg org "$AZURE_DEVOPS_ORG" \
    --arg auth_mode "$auth_mode" \
    --argjson identity "$identity_json" \
    --argjson capabilities "$capabilities" \
    --argjson access_ok "$access_ok" \
    --arg summary "$summary" \
    --arg report "$report" \
    '{organization:$org, auth_mode:$auth_mode, identity:$identity, capabilities:$capabilities, access_ok:$access_ok, summary:$summary, report:$report}')

# Last-resort guard: the results file must ALWAYS be valid JSON so the runbook
# never has to fall back to a contentless "results unavailable" placeholder.
if [ -z "$result_json" ] || ! echo "$result_json" | jq -e . >/dev/null 2>&1; then
    result_json=$(jq -n --arg s "$summary" --arg r "${report:-$summary}" --argjson ok "${access_ok:-false}" \
        '{access_ok:$ok, summary:$s, report:$r}')
fi

echo "$result_json" > "$OUTPUT_FILE"
echo "Results saved to $OUTPUT_FILE"
