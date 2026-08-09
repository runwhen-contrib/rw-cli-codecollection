#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Environment to Instance Attachment Coverage
#
# For each environment, verifies it is attached to at least one runtime
# instance. Flags any environment with zero instance attachments, which means
# nothing routes or serves it even though the environment itself is configured
# correctly.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that owns the Apigee organization
#
# OPTIONAL ENV VARS:
#   APIGEE_ORG       - Apigee org name; when empty it falls back to the org
#                      discover_topology.sh recorded in apigee_topology.json
#   ENVIRONMENTS     - comma-separated env filter, or 'All' for every env
#
# INPUTS:
#   apigee_topology.json  - produced by discover_topology.sh
#
# OUTPUTS:
#   instance_attachment_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"
: "${ENVIRONMENTS:=All}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="instance_attachment_issues.json"
issues_json='[]'

if [ ! -f "apigee_topology.json" ]; then
    echo "Topology dump missing; run discover_topology.sh first." >&2
    echo "[]" > "${ISSUES_FILE}"
    exit 0
fi

APIGEE_ORG="$(apigee_resolve_org)"
if [ -z "${APIGEE_ORG}" ]; then
    echo "No Apigee organization set or discoverable from the topology dump; see discovery_issues.json." >&2
    echo "[]" > "${ISSUES_FILE}"
    exit 0
fi

echo "Checking environment-to-instance attachment coverage for Apigee org: ${APIGEE_ORG}"

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
    attached_count=$(jq -r --arg e "${env}" '[(.environments // [])[] | select(.name==$e) | .attached_instances[]?] | length' apigee_topology.json)
    attached_list=$(jq -r --arg e "${env}" '[(.environments // [])[] | select(.name==$e) | .attached_instances[]?] | join(", ")' apigee_topology.json)
    if [ "${attached_count:-0}" -eq 0 ]; then
        issue=$(jq -n \
            --arg title "Apigee environment \`${env}\` has no attached runtime instance" \
            --arg details "Environment '${env}' in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) is configured but has zero runtime instance attachments. No instance can serve traffic routed to this environment, so every attached hostname returns errors despite the environment appearing healthy." \
            --arg severity "2" \
            --arg expected "Every environment should be attached to at least one runtime instance so traffic can be served." \
            --arg actual "Environment '${env}' has ${attached_count} instance attachment(s)." \
            --arg next_steps "Attach the environment to an instance: gcloud apigee instances attachments create --environment=${env} --instance=<instance> --organization=${APIGEE_ORG} (or via REST organizations/{org}/instances/{instance}/attachments)." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
        echo "  Environment '${env}' has NO instance attachment (ISSUE)"
    else
        echo "  Environment '${env}' attached to: ${attached_list}"
    fi
done

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Instance attachment coverage check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
