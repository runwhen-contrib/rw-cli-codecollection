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
#   org_env_state_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"
: "${ENVIRONMENTS:=All}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="org_env_state_issues.json"
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

org_state=$(jq -r '.org.state // ""' apigee_topology.json)
echo "Checking organization and environment state for Apigee org: ${APIGEE_ORG} (org state=${org_state})"

HEALTHY="ACTIVE"

# --- Organization state ---
if [ -n "${org_state}" ] && [ "${org_state}" != "${HEALTHY}" ]; then
    severity="2"
    if [ "${org_state}" = "FAILED" ] || [ "${org_state}" = "UNKNOWN" ]; then
        severity="3"
    fi
    # No org name and no state in the title: the SLX is scoped to one project,
    # which holds exactly one org, and a state that moves CREATING -> UPDATING
    # -> FAILED would otherwise open a new issue at every transition.
    issue=$(jq -n \
        --arg title "Apigee organization is not ACTIVE" \
        --arg details "Organization ${APIGEE_ORG} in project ${GCP_PROJECT_ID} has state '${org_state}'. A non-ACTIVE organization cannot serve any traffic for its environments and environment groups." \
        --arg severity "${severity}" \
        --arg expected "The Apigee organization should be in ACTIVE state." \
        --arg actual "Organization ${APIGEE_ORG} is in state '${org_state}'." \
        --arg next_steps "Open a GCP support case or inspect the Apigee org provisioning/health in the console. The org may be mid-provision or in a failed state." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

# --- Environment state (one GET per environment) ---
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

# Collected per failure mode, then raised once each. Grouping keeps the severity
# split the per-environment version had: a stuck provisioning state is a
# different finding from a failed one, so they stay separate issues rather than
# being merged and losing that distinction.
unreadable=""
not_active=""
provisioning=""

for env in "${env_array[@]}"; do
    env=$(echo "${env}" | xargs)
    [ -z "${env}" ] && continue
    env_detail=$(apigee_get "organizations/${APIGEE_ORG}/environments/${env}")
    if [ -z "${env_detail}" ]; then
        unreadable="${unreadable}  - ${env}
"
        echo "  Environment '${env}' could not be read"
        continue
    fi
    env_state=$(echo "${env_detail}" | jq -r '.state // ""')
    if [ -n "${env_state}" ] && [ "${env_state}" != "${HEALTHY}" ]; then
        if [ "${env_state}" = "CREATING" ] || [ "${env_state}" = "UPDATING" ]; then
            provisioning="${provisioning}  - ${env} (state=${env_state})
"
        else
            not_active="${not_active}  - ${env} (state=${env_state})
"
        fi
        echo "  Environment '${env}' state=${env_state}"
    else
        echo "  Environment '${env}' state=${env_state} (healthy)"
    fi
done

# names <list>  -- "a, b, c" from the indented bullet list built above
names() { printf '%s' "$1" | sed 's/^  - //' | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
count() { printf '%s' "$1" | grep -c .; }

if [ -n "${unreadable}" ]; then
    issue=$(jq -n \
        --arg title "Apigee environments could not be read" \
        --arg details "GET organizations/${APIGEE_ORG}/environments/<env> returned no data for the following environment(s) in project ${GCP_PROJECT_ID}:
${unreadable}
Their state is unknown, so this check cannot vouch for them." \
        --arg severity "3" \
        --arg expected "Every environment should be retrievable so its state can be assessed." \
        --arg actual "$(count "${unreadable}") environment(s) could not be read: $(names "${unreadable}")." \
        --arg next_steps "Verify the service account has apigee.environments.get and that the listed environments exist." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${not_active}" ]; then
    issue=$(jq -n \
        --arg title "Apigee environments are not ACTIVE" \
        --arg details "The following environment(s) in org ${APIGEE_ORG} are not ACTIVE:
${not_active}
A non-ACTIVE environment cannot serve requests for any hostname attached to it, which is a total outage for those hostnames." \
        --arg severity "3" \
        --arg expected "Every environment should be in ACTIVE state." \
        --arg actual "$(count "${not_active}") environment(s) not ACTIVE: $(names "${not_active}")." \
        --arg next_steps "Investigate why each listed environment is not ACTIVE. For FAILED, delete and recreate the environment or open a support case." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${provisioning}" ]; then
    issue=$(jq -n \
        --arg title "Apigee environments are still provisioning" \
        --arg details "The following environment(s) in org ${APIGEE_ORG} are mid-provision:
${provisioning}
They cannot serve requests until they reach ACTIVE. This often resolves on its own; if it persists, treat it as stuck." \
        --arg severity "2" \
        --arg expected "Every environment should reach ACTIVE state." \
        --arg actual "$(count "${provisioning}") environment(s) provisioning: $(names "${provisioning}")." \
        --arg next_steps "Re-check shortly. If an environment stays in CREATING or UPDATING, open a support case." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Organization/environment state check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
