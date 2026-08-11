#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Environment Group Attachments and Hostname Routing
#
# For each environment group, verifies it has at least one attachment and that
# its hostnames are routed to an attached environment. Flags environment groups
# with no attached environment, and hostnames that are not routed, which produce
# edge-level 404s for callers.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that owns the Apigee organization
#
# OPTIONAL ENV VARS:
#   APIGEE_ORG       - Apigee org name; when empty it falls back to the org
#                      discover_topology.sh recorded in apigee_topology.json
#
# INPUTS:
#   apigee_topology.json  - produced by discover_topology.sh
#
# OUTPUTS:
#   envgroup_attachment_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="envgroup_attachment_issues.json"
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

echo "Checking environment group attachments and hostname routing for Apigee org: ${APIGEE_ORG}"

envgroups_total=$(jq '[.envgroups[]?] | length' apigee_topology.json)
if [ "${envgroups_total}" -eq 0 ]; then
    echo "No environment groups found in org ${APIGEE_ORG}."
    echo "${issues_json}" > "${ISSUES_FILE}"
    exit 0
fi

while read -r eg; do
    eg_name=$(echo "${eg}" | jq -r '.name // empty' | xargs -r basename)
    [ -z "${eg_name}" ] && continue
    hostnames=$(echo "${eg}" | jq -c '.hostnames // []')
    attachments=$(jq -c --arg eg "${eg_name}" '.envgroup_attachments[$eg] // []' apigee_topology.json)
    attach_count=$(echo "${attachments}" | jq 'length')
    attach_list=$(echo "${attachments}" | jq -r 'join(", ")')

    echo "  Env group '${eg_name}': ${attach_count} attachment(s) [${attach_list}], hostnames: $(echo "${hostnames}" | jq -r 'join(", ")')"

    # 1. Env group with no attachments -> cannot route anything
    if [ "${attach_count}" -eq 0 ]; then
        issue=$(jq -n \
            --arg title "Apigee environment group \`${eg_name}\` has no attached environments" \
            --arg details "Environment group '${eg_name}' in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) has zero environment attachments. Its hostnames (${hostnames}) cannot route to any environment, producing edge-level 404s." \
            --arg severity "2" \
            --arg expected "Every environment group should have at least one attached environment so hostnames route correctly." \
            --arg actual "Environment group '${eg_name}' has ${attach_count} attachment(s)." \
            --arg next_steps "Attach at least one environment to the group via REST POST organizations/{org}/envgroups/{eg}/attachments with the environment name." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
    fi

    # 2. No hostnames configured -> nothing can reach the group from the edge
    hostname_count=$(echo "${hostnames}" | jq 'length')
    if [ "${hostname_count}" -eq 0 ]; then
        issue=$(jq -n \
            --arg title "Apigee environment group \`${eg_name}\` has no routing hostnames" \
            --arg details "Environment group '${eg_name}' in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) has no hostnames configured, so no inbound traffic can be routed to its attached environments." \
            --arg severity "2" \
            --arg expected "Every environment group should have at least one hostname configured." \
            --arg actual "Environment group '${eg_name}' has 0 hostnames." \
            --arg next_steps "Add hostnames to the environment group via REST PATCH organizations/{org}/envgroups/{eg} and ensure DNS for those hostnames points to the org's ingress IP." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
    fi
done < <(jq -c '.envgroups[]?' apigee_topology.json)

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Environment group attachment check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
