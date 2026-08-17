#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover Apigee Proxies and Environments for Metrics
#
# Enumerates API proxies, environments, and target servers at org scope to
# scope the metric checks and map proxy/environment labels for the Cloud
# Monitoring queries. Uses the Apigee Admin API.
#
# Runs from Suite Initialization, NOT as a task: it can raise no finding about
# Apigee itself, only about its own ability to run. As a task it produced a
# dishonest task list -- when it failed, every check still ran against an empty
# scope, found nothing and rendered as passed, which is indistinguishable from a
# healthy org.
#
# Two outcomes are kept distinct:
#   positive determination of absence (an org with no proxies) -> not a finding
#   failure to determine (auth, permission, unreachable)       -> issue + suite
#                                                                 failure
#
# REQUIRED ENV VARS:
#   APIGEE_ORG         - Apigee organization name, supplied by the SLX
#   GCP_PROJECT_ID     - GCP project ID hosting the Apigee runtime
#
# OPTIONAL ENV VARS:
#   MOCK_DATA_FILE     - Path to a mock scope JSON file (for deterministic tests)
#   APIGEE_API         - base URL of the Apigee management API (default v1)
#
# OUTPUTS:
#   apigee_scope.json      - Enriched scope object (proxies, environments, targets)
#   discovery_issues.json  - JSON array of issues (empty on success)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"
: "${APIGEE_API:=https://apigee.googleapis.com/v1}"

SCOPE_FILE="apigee_scope.json"
ISSUES_FILE="discovery_issues.json"
issues_json='[]'

# Strip the resource-name prefix: every call below interpolates the result into
# a REST path that already carries it.
APIGEE_ORG="${APIGEE_ORG#organizations/}"

add_issue() {
    # add_issue <title> <severity> <expected> <actual> <details> <next_steps>
    issues_json=$(echo "${issues_json}" | jq \
        --arg title "$1" --arg severity "$2" --arg expected "$3" \
        --arg actual "$4" --arg details "$5" --arg next_steps "$6" \
        '. += [{"title":$title,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"details":$details,"next_steps":$next_steps}]')
}

fail_out() {
    echo "${issues_json}" > "${ISSUES_FILE}"
    echo '{}' > "${SCOPE_FILE}"
    echo "Discovery failed. Issues written to ${ISSUES_FILE}"
    exit 0
}

# The ONLY place the project is the right identifier: the org is precisely what
# could not be determined, so it is not available to name.
if [ -z "${APIGEE_ORG}" ]; then
    add_issue \
        "Cannot determine the Apigee organization in project \`${GCP_PROJECT_ID}\`" \
        "3" \
        "APIGEE_ORG should be supplied by the SLX, which is generated from the indexed Apigee organization." \
        "APIGEE_ORG was empty, so no Apigee API call can be scoped." \
        "The generation rule gates on gcp_apigee_organizations and both templates resolve APIGEE_ORG from the matched resource, so an empty value means the SLX was rendered without an indexed organization payload or with a blank custom.apigee_org override." \
        "Check the workspaceInfo custom.apigee_org value, and confirm the Apigee organization is indexed for project ${GCP_PROJECT_ID}."
    fail_out
fi

echo "Discovering Apigee scope for org: ${APIGEE_ORG} (project: ${GCP_PROJECT_ID})"

# Use mock data if provided (deterministic test mode), else live Apigee API.
if [ -n "${MOCK_DATA_FILE:-}" ] && [ -f "${MOCK_DATA_FILE}" ]; then
    echo "Using mock scope data from ${MOCK_DATA_FILE}"
    cp "${MOCK_DATA_FILE}" "${SCOPE_FILE}"
    echo "Scope written to ${SCOPE_FILE} from mock data."
    echo "${issues_json}" > "${ISSUES_FILE}"
    cat "${SCOPE_FILE}"
    exit 0
fi

# xtrace is suppressed around every use of the token. `set -x` would otherwise
# write a live OAuth bearer token into the task's captured output -- at the
# ASSIGNMENT as well as at the request, so wrapping only the curl is insufficient.
{ set +x; } 2>/dev/null
access_token=$(gcloud auth print-access-token 2>/dev/null || echo "")
# The emptiness test runs BEFORE tracing is restored. Re-enabling first would put
# `+ [ -z ya29.a0Af... ]` in the trace -- the same leak, moved.
if [ -n "${access_token}" ]; then have_token=1; else have_token=0; fi
set -x
if [ "${have_token}" = "0" ]; then
    add_issue \
        "Cannot authenticate to Apigee in org \`${APIGEE_ORG}\`" \
        "4" \
        "Apigee organization resources should be retrievable." \
        "Could not obtain an access token, so nothing about this org was determined." \
        "Unable to obtain an access token via gcloud for the Apigee Admin API in project ${GCP_PROJECT_ID}." \
        "Ensure the service account has roles/apigee.readOnlyAdmin (or apigee.proxyviewer) and that Suite Initialization's token probe passed."
    fail_out
fi

BASE="${APIGEE_API}/organizations/${APIGEE_ORG}"

api_get() {
    local _b
    { set +x; } 2>/dev/null
    _b=$(curl -s -H "Authorization: Bearer ${access_token}" "$1" 2>/dev/null) || _b=""
    set -x
    [ -n "${_b}" ] || _b="{}"
    printf '%s' "${_b}"
}

# --- Proxies ------------------------------------------------------------------
# GET organizations/{org}/apis returns GoogleCloudApigeeV1ListApiProxiesResponse:
# {"proxies":[{"name":...}]}. Confirmed against the v1 discovery document.
proxies_resp=$(api_get "${BASE}/apis")
if echo "${proxies_resp}" | jq -e 'has("error")' >/dev/null 2>&1; then
    err=$(echo "${proxies_resp}" | jq -r '.error.message // "unknown error"')
    add_issue \
        "Cannot list Apigee proxies in org \`${APIGEE_ORG}\`" \
        "4" \
        "API proxies should be enumerable so the metric checks can be scoped." \
        "Listing proxies failed, so no proxy was evaluated." \
        "Apigee Admin API /apis failed for org ${APIGEE_ORG} in project ${GCP_PROJECT_ID}: ${err}" \
        "Verify the service account has apigee.proxies.list permission and that the Apigee API is enabled on the project."
    fail_out
fi
proxies=$(echo "${proxies_resp}" | jq -r '.proxies[]?.name // empty' 2>/dev/null || true)

# --- Environments -------------------------------------------------------------
# GET organizations/{org}/environments has NO entry in the v1 discovery document
# and returns a BARE ARRAY OF STRINGS, e.g. ["prod","test"]. Reading it as an
# object with a named list field yields nothing and the whole run then evaluates
# an empty scope while reporting success.
envs_resp=$(api_get "${BASE}/environments")
envs=$(echo "${envs_resp}" | jq -r 'if type=="array" then .[] else empty end' 2>/dev/null || true)

# --- Target servers per environment -------------------------------------------
# Same shape trap: organizations/{org}/environments/{env}/targetservers is also
# absent from the discovery document and also returns a BARE ARRAY OF STRINGS.
# This previously read `.targetServers[].name`, which matches no real response,
# so target_servers was ALWAYS empty and Check Apigee Target and Backend
# Performance silently evaluated nothing while rendering as passed.
target_servers_json='[]'
if [ -n "${envs}" ]; then
    while IFS= read -r env_name; do
        [ -z "${env_name}" ] && continue
        ts_resp=$(api_get "${BASE}/environments/${env_name}/targetservers")
        ts_names=$(echo "${ts_resp}" | jq -r 'if type=="array" then .[] else empty end' 2>/dev/null || true)
        [ -z "${ts_names}" ] && continue
        while IFS= read -r ts; do
            [ -z "${ts}" ] && continue
            target_servers_json=$(echo "${target_servers_json}" | jq \
                --arg name "${ts}" --arg env "${env_name}" \
                '. += [{"name":$name,"environment":$env}]')
        done <<< "${ts_names}"
    done <<< "${envs}"
fi

# --- Assemble scope -----------------------------------------------------------
to_array() { printf '%s' "$1" | jq -Rrs 'split("\n") | map(select(length>0))'; }

jq -n \
    --arg org "${APIGEE_ORG}" \
    --arg project "${GCP_PROJECT_ID}" \
    --argjson proxies "$(to_array "${proxies}")" \
    --argjson environments "$(to_array "${envs}")" \
    --argjson target_servers "${target_servers_json}" \
    '{organization:$org, project:$project, proxies:$proxies, environments:$environments, target_servers:$target_servers}' > "${SCOPE_FILE}"

# An org with no proxies is a positive determination of absence, not a finding.
echo "Discovered $(jq '.proxies | length' "${SCOPE_FILE}") proxy(ies), $(jq '.environments | length' "${SCOPE_FILE}") environment(s), and $(jq '.target_servers | length' "${SCOPE_FILE}") target server(s)."

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Scope written to ${SCOPE_FILE}"
cat "${SCOPE_FILE}"
