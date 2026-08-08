#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Organization and Environment State
#
# Flags the organization if it is not ACTIVE, and flags every environment that
# is not in a healthy ACTIVE state or is stuck in CREATING/UPDATING/FAILED,
# since a non-serving environment is a total outage for its attached hostnames.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that owns the Apigee organization
#   APIGEE_ORG       - Apigee org name
#
# OPTIONAL ENV VARS:
#   ENVIRONMENTS     - comma-separated env filter, or 'All' for every env
#
# INPUTS:
#   apigee_topology.json  - produced by discover_topology.sh
#
# OUTPUTS:
#   org_env_state_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${ENVIRONMENTS:=All}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="org_env_state_issues.json"
issues_json='[]'

if [ ! -f "apigee_topology.json" ]; then
    echo "Topology dump missing; run discover_topology.sh first." >&2
    echo "[]" > "${ISSUES_FILE}"
    exit 0
fi

org_state=$(jq -r '.org.state // ""' apigee_topology.json)
echo "Checking organization and environment state for Apigee org: ${APIGEE_ORG} (org state=${org_state})"

HEALTHY="ACTIVE"

# --- Organization state ---
if [ -n "${org_state}" ] && [ "${org_state}" != "${HEALTHY}" ]; then
    severity="2"
    if [ "${org_state}" = "FAILED" ] || [ "${org_state}" = "UNKNOWN" ]; then
        severity="3"
    fi
    issue=$(jq -n \
        --arg title "Apigee organization \`${APIGEE_ORG}\` is not ACTIVE (state=${org_state})" \
        --arg details "Organization ${APIGEE_ORG} in project ${GCP_PROJECT_ID} has state '${org_state}'. A non-ACTIVE organization cannot serve any traffic for its environments and environment groups." \
        --arg severity "${severity}" \
        --arg expected "Organization ${APIGEE_ORG} should be in ACTIVE state." \
        --arg actual "Organization state is '${org_state}'." \
        --arg next_steps "Open a GCP support case or inspect the Apigee org provisioning/health in the console. The org may be mid-provision or in a failed state." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

# --- Environment state (one GET per environment) ---
envs=$(jq -r '[.environments[].name] | join(",")' apigee_topology.json)
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
    env_detail=$(apigee_get "organizations/${APIGEE_ORG}/environments/${env}")
    if [ -z "${env_detail}" ]; then
        issue=$(jq -n \
            --arg title "Cannot access Apigee environment \`${env}\` in org \`${APIGEE_ORG}\`" \
            --arg details "GET organizations/${APIGEE_ORG}/environments/${env} returned no data for project ${GCP_PROJECT_ID}." \
            --arg severity "3" \
            --arg expected "Environment ${env} should be retrievable and in a healthy state." \
            --arg actual "Environment ${env} could not be read (possible permission or provision error)." \
            --arg next_steps "Verify the service account has apigee.environments.get and that the environment exists." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
        continue
    fi
    env_state=$(echo "${env_detail}" | jq -r '.state // ""')
    if [ -n "${env_state}" ] && [ "${env_state}" != "${HEALTHY}" ]; then
        severity="3"
        if [ "${env_state}" = "CREATING" ] || [ "${env_state}" = "UPDATING" ]; then
            severity="2"
        fi
        issue=$(jq -n \
            --arg title "Apigee environment \`${env}\` is not ACTIVE (state=${env_state})" \
            --arg details "Environment '${env}' in org ${APIGEE_ORG} has state '${env_state}'. A non-ACTIVE environment cannot serve requests for any hostname attached to it, which is a total outage." \
            --arg severity "${severity}" \
            --arg expected "Environment ${env} should be in ACTIVE state." \
            --arg actual "Environment state is '${env_state}'." \
            --arg next_steps "Investigate why the environment is not ACTIVE. For CREATING/UPDATING this may resolve itself; for FAILED, delete and recreate the environment or open a support case." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
        echo "  Environment '${env}' state=${env_state}"
    else
        echo "  Environment '${env}' state=${env_state} (healthy)"
    fi
done

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Organization/environment state check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
