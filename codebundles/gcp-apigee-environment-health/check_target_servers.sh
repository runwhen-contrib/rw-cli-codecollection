#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Target Server Configuration and Reachability
#
# For each target server per environment, verifies it is enabled and that its
# referenced host resolves and its port is reachable. Flags disabled target
# servers and dangling targets whose host no longer resolves, which break every
# call routed to them. A disabled/reachable-failed target server produces a
# southbound target_error seen by the proxy bundle.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that owns the Apigee organization
#
# OPTIONAL ENV VARS:
#   APIGEE_ORG                   - Apigee org name; when empty it falls back to
#                                  the org discover_topology.sh recorded
#   ENVIRONMENTS                 - comma-separated env filter, or 'All'
#   TARGET_REACHABILITY_TIMEOUT  - seconds for the host/port probe (default 5)
#
# INPUTS:
#   apigee_topology.json  - produced by discover_topology.sh
#
# OUTPUTS:
#   target_server_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"
: "${ENVIRONMENTS:=All}"
: "${TARGET_REACHABILITY_TIMEOUT:=5}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="target_server_issues.json"
issues_json='[]'
disabled=""
unresolvable=""
unreachable=""

# Suite Initialization runs discovery and fails the suite if it could not
# produce a topology, so by the time this runs the file is guaranteed to
# exist. A missing one means something is genuinely wrong -- treating it as
# an empty environment here would report "no issues found" for a check that
# never looked at anything.
if [ ! -f "apigee_topology.json" ]; then
    echo "ERROR: apigee_topology.json is missing. Discovery runs in Suite Initialization;" >&2
    echo "       if you are running this script directly, run discover_topology.sh first." >&2
    exit 1
fi

APIGEE_ORG="$(apigee_resolve_org)"
if [ -z "${APIGEE_ORG}" ]; then
    echo "No Apigee organization set or discoverable from the topology dump; see discovery_issues.json." >&2
    echo "[]" > "${ISSUES_FILE}"
    exit 0
fi

echo "Checking target server configuration and reachability for Apigee org: ${APIGEE_ORG}"

envs=$(jq -r '[(.environments // [])[].name] | join(",")' apigee_topology.json)
if [ -n "${ENVIRONMENTS}" ] && [ "${ENVIRONMENTS}" != "All" ] && [ "${ENVIRONMENTS}" != "all" ]; then
    envs="${ENVIRONMENTS}"
fi

IFS=',' read -r -a env_array <<< "${envs}"
if [ "${#env_array[@]}" -eq 0 ] || { [ "${#env_array[@]}" -eq 1 ] && [ -z "${env_array[0]}" ]; }; then
    echo "No environments to check."
    echo "${issues_json}" > "${ISSUES_FILE}"
    exit 0
fi

for env in "${env_array[@]}"; do
    env=$(echo "${env}" | xargs)
    [ -z "${env}" ] && continue
    targetservers=$(apigee_get "organizations/${APIGEE_ORG}/environments/${env}/targetservers")
    # `[ "$x" != "["* ]` does NOT pattern-match inside test, so it skipped every
    # real target server list and reported clean. Use case for the array check.
    case "${targetservers}" in
        \[*) ;;
        *)
            echo "  No target servers accessible for environment '${env}'"
            continue
            ;;
    esac
    echo "  Checking target servers for environment '${env}'"

    for ts in $(echo "${targetservers}" | jq -r '.[]?'); do
        ts=$(echo "${ts}" | xargs)
        [ -z "${ts}" ] && continue
        ts_detail=$(apigee_get "organizations/${APIGEE_ORG}/environments/${env}/targetservers/${ts}")
        if [ -z "${ts_detail}" ]; then
            continue
        fi
        host=$(echo "${ts_detail}" | jq -r '.host // ""')
        port=$(echo "${ts_detail}" | jq -r '.port // 80')
        # `.isEnabled // true` would report a DISABLED target server as enabled:
        # jq's // falls through on false as well as null. Test for the key.
        is_enabled=$(echo "${ts_detail}" | jq -r 'if has("isEnabled") then .isEnabled else true end')
        ssl_info=$(echo "${ts_detail}" | jq -r 'if (.sSLInfo | type) == "object" and (.sSLInfo | has("enabled")) then .sSLInfo.enabled else false end')
        echo "    Target server '${ts}': host=${host} port=${port} enabled=${is_enabled} ssl=${ssl_info}"

        # Collected per failure mode; raised once each after the loops.
        # 1. Target server explicitly disabled
        if [ "${is_enabled}" != "true" ]; then
            disabled="${disabled}  - ${ts} in environment ${env} (host ${host}:${port})
"
        fi

        # 2. Host does not resolve -> dangling target
        if ! getent hosts "${host}" >/dev/null 2>&1; then
            unresolvable="${unresolvable}  - ${ts} in environment ${env} -> host '${host}' does not resolve
"
            continue
        fi

        # 3. Port unreachable -> southbound connectivity problem
        if ! timeout "${TARGET_REACHABILITY_TIMEOUT}" bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
            unreachable="${unreachable}  - ${ts} in environment ${env} -> ${host}:${port} did not accept a connection
"
        else
            echo "      Target server '${ts}' reachable at ${host}:${port}"
        fi
    done
done

names() { printf '%s' "$1" | sed 's/^  - //; s/ in environment.*//; s/ (host.*//' | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
count() { printf '%s' "$1" | grep -c .; }

if [ -n "${disabled}" ]; then
    issue=$(jq -n \
        --arg title "Apigee target servers are disabled in org \`${APIGEE_ORG}\`" \
        --arg details "The following target server(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) are disabled:
${disabled}
Every proxy call routed to them fails with a target_error." \
        --arg severity "3" \
        --arg expected "Target servers should be enabled so traffic can flow to the backend." \
        --arg actual "$(count "${disabled}") disabled target server(s): $(names "${disabled}")." \
        --arg next_steps "Enable each listed target server via REST PATCH organizations/{org}/environments/{env}/targetservers/{ts}, or in the Apigee UI, once its backend is ready to receive traffic." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${unresolvable}" ]; then
    issue=$(jq -n \
        --arg title "Apigee target servers reference unresolvable hosts in org \`${APIGEE_ORG}\`" \
        --arg details "The following target server(s) in org ${APIGEE_ORG} point at hosts that do not resolve via DNS:
${unresolvable}
Every call routed to them fails at the southbound edge." \
        --arg severity "3" \
        --arg expected "Every target server host should resolve to a reachable backend IP." \
        --arg actual "$(count "${unresolvable}") target server(s) with unresolvable hosts: $(names "${unresolvable}")." \
        --arg next_steps "Fix the DNS record, or update each listed target server's host to a resolvable backend address via REST PATCH organizations/{org}/environments/{env}/targetservers/{ts}." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${unreachable}" ]; then
    issue=$(jq -n \
        --arg title "Apigee target servers are unreachable in org \`${APIGEE_ORG}\`" \
        --arg details "The following target server(s) in org ${APIGEE_ORG} resolve but did not accept a TCP connection within ${TARGET_REACHABILITY_TIMEOUT}s:
${unreachable}
Southbound calls to them will time out or error." \
        --arg severity "3" \
        --arg expected "Every target server host:port should be reachable from the Apigee org's VPC." \
        --arg actual "$(count "${unreachable}") unreachable target server(s): $(names "${unreachable}")." \
        --arg next_steps "Verify each backend is up and that the Apigee org's VPC peering / Private Service Connect can reach it. Check firewall rules and service health." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Target server check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
