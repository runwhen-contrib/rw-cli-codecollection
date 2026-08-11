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

        # 1. Target server explicitly disabled
        if [ "${is_enabled}" != "true" ]; then
            issue=$(jq -n \
                --arg title "Apigee target server \`${ts}\` in \`${env}\` is disabled" \
                --arg details "Target server '${ts}' in environment '${env}' (org ${APIGEE_ORG}, project ${GCP_PROJECT_ID}) is disabled. Every proxy call routed to this target server will fail with a target_error." \
                --arg severity "3" \
                --arg expected "Target servers should be enabled so traffic can flow to the backend." \
                --arg actual "Target server '${ts}' has isEnabled=false." \
                --arg next_steps "Enable the target server via REST PATCH organizations/{org}/environments/{env}/targetservers/{ts} or re-enable it in the Apigee UI, once the backend is ready to receive traffic." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
        fi

        # 2. Host does not resolve -> dangling target
        if ! getent hosts "${host}" >/dev/null 2>&1; then
            issue=$(jq -n \
                --arg title "Apigee target server \`${ts}\` in \`${env}\` references unresolvable host \`${host}\`" \
                --arg details "Target server '${ts}' in environment '${env}' (org ${APIGEE_ORG}) points at host '${host}' which does not resolve via DNS. Every call routed to it will fail at the southbound edge." \
                --arg severity "3" \
                --arg expected "The target server host should resolve to a reachable backend IP." \
                --arg actual "Host '${host}' for target server '${ts}' does not resolve." \
                --arg next_steps "Fix the DNS record or update the target server host to a valid, resolvable backend address via REST PATCH organizations/{org}/environments/{env}/targetservers/{ts}." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
            continue
        fi

        # 3. Port unreachable -> southbound connectivity problem
        if ! timeout "${TARGET_REACHABILITY_TIMEOUT}" bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
            issue=$(jq -n \
                --arg title "Apigee target server \`${ts}\` in \`${env}\` port ${port} is unreachable" \
                --arg details "Target server '${ts}' host '${host}' resolves but TCP port ${port} in environment '${env}' (org ${APIGEE_ORG}) did not accept a connection within ${TARGET_REACHABILITY_TIMEOUT}s. Southbound calls will time out or error." \
                --arg severity "3" \
                --arg expected "The target server host:port should be reachable from the Apigee org's VPC." \
                --arg actual "TCP connect to ${host}:${port} failed within ${TARGET_REACHABILITY_TIMEOUT}s." \
                --arg next_steps "Verify the backend is up and that the Apigee org's VPC peering / Private Service Connect can reach ${host}:${port}. Check firewall rules and service health." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
        else
            echo "      Target server '${ts}' reachable at ${host}:${port}"
        fi
    done
done

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Target server check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
