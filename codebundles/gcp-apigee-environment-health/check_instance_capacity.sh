#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Instance Capacity and Regional Failover
#
# Flags runtime instances whose state is not ACTIVE (a serving outage for every
# attached environment), surfaces CPU/capacity consumption when available, and
# reports whether any environment is served by only a single region/instance
# (no failover) so operators understand their resilience posture.
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
#   capacity_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="capacity_issues.json"
issues_json='[]'
inst_not_active=""
inst_provisioning=""
reduced=""
no_failover=""

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

echo "Checking instance capacity and regional failover for Apigee org: ${APIGEE_ORG}"

instances_total=$(jq '[.instances[]?] | length' apigee_topology.json)
if [ "${instances_total}" -eq 0 ]; then
    issue=$(jq -n \
        --arg title "Apigee organization \`${APIGEE_ORG}\` has no runtime instances" \
        --arg details "Organization ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) has zero runtime instances. No environments can be served." \
        --arg severity "3" \
        --arg expected "The Apigee org should have at least one runtime instance to serve traffic." \
        --arg actual "No instances found in the org." \
        --arg next_steps "Provision at least one runtime instance and attach the environments to it." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
    echo "${issues_json}" > "${ISSUES_FILE}"
    echo "No instances found; check complete with 1 issue(s)."
    exit 0
fi

# --- Per-instance state and capacity ---
while read -r inst; do
    inst_name=$(echo "${inst}" | jq -r '.name // empty' | xargs -r basename)
    [ -z "${inst_name}" ] && continue
    inst_state=$(echo "${inst}" | jq -r '.state // ""')
    inst_location=$(echo "${inst}" | jq -r '.location // ""')
    inst_hostname=$(echo "${inst}" | jq -r '.hostname // ""')
    echo "  Instance '${inst_name}' state=${inst_state} location=${inst_location} host=${inst_hostname}"

    if [ -n "${inst_state}" ] && [ "${inst_state}" != "ACTIVE" ]; then
        if [ "${inst_state}" = "CREATING" ] || [ "${inst_state}" = "UPDATING" ]; then
            inst_provisioning="${inst_provisioning}  - ${inst_name} at ${inst_location} (state=${inst_state})
"
        else
            inst_not_active="${inst_not_active}  - ${inst_name} at ${inst_location} (state=${inst_state})
"
        fi
    fi

    # Capacity (CPU) via asyncRuntime entity; degrade gracefully if unavailable.
    cap_body=$(apigee_get "organizations/${APIGEE_ORG}/instances/${inst_name}?entity=asyncRuntime")
    if [ -n "${cap_body}" ]; then
        cap_units_total=$(echo "${cap_body}" | jq -r '.capacityUnits // empty')
        cap_units_used=$(echo "${cap_body}" | jq -r '.usageInfo.capacityUnitsUsed // empty')
        reduction=$(echo "${cap_body}" | jq -r '.reductionStatus.status // ""')
        echo "    capacityUnits=${cap_units_total} used=${cap_units_used} reduction=${reduction}"
        if [ -n "${reduction}" ] && [ "${reduction}" != "" ] && [ "${reduction}" != "NORMAL" ]; then
            reduced="${reduced}  - ${inst_name} at ${inst_location} (reduction status: ${reduction})
"
        fi
    fi
done < <(jq -c '.instances[]?' apigee_topology.json)

# --- Regional failover posture per environment ---
while read -r env; do
    env_name=$(echo "${env}" | jq -r '.name // empty')
    [ -z "${env_name}" ] && continue
    attached=$(echo "${env}" | jq -r '[.attached_instances[]?] | length')
    unique_locations=$(echo "${env}" | jq -r --argjson instlist "$(jq -c '.instances // []' apigee_topology.json)" '
        [ .attached_instances[]? as $n | $instlist[] | select(.name | endswith("/"+$n)) | .location // "" ] | unique | length')
    if [ "${attached:-0}" -eq 1 ]; then
        no_failover="${no_failover}  - ${env_name} (1 instance across ${unique_locations} region)
"
        echo "  Environment '${env_name}' has no failover (single instance/region)"
    else
        echo "  Environment '${env_name}' attached to ${attached} instance(s) across ${unique_locations} region(s)"
    fi
done < <(jq -c '.environments[]?' apigee_topology.json)

names() { printf '%s' "$1" | sed 's/^  - //; s/ (.*//; s/ at .*//' | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
count() { printf '%s' "$1" | grep -c .; }

if [ -n "${inst_not_active}" ]; then
    issue=$(jq -n \
        --arg title "Apigee runtime instances are not ACTIVE in org \`${APIGEE_ORG}\`" \
        --arg details "The following runtime instance(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) are not ACTIVE:
${inst_not_active}
Every environment attached to them cannot be served." \
        --arg severity "3" \
        --arg expected "Runtime instances should be in ACTIVE state." \
        --arg actual "$(count "${inst_not_active}") instance(s) not ACTIVE: $(names "${inst_not_active}")." \
        --arg next_steps "Investigate each listed instance and recreate it via the Apigee UI or REST if it is FAILED." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${inst_provisioning}" ]; then
    issue=$(jq -n \
        --arg title "Apigee runtime instances are still provisioning in org \`${APIGEE_ORG}\`" \
        --arg details "The following runtime instance(s) in org ${APIGEE_ORG} are mid-provision:
${inst_provisioning}
Environments attached to them cannot be served until they reach ACTIVE." \
        --arg severity "2" \
        --arg expected "Runtime instances should reach ACTIVE state." \
        --arg actual "$(count "${inst_provisioning}") instance(s) provisioning: $(names "${inst_provisioning}")." \
        --arg next_steps "Instance creation is slow; re-check shortly. If one stays in CREATING or UPDATING, open a support case." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${reduced}" ]; then
    issue=$(jq -n \
        --arg title "Apigee runtime instances are in reduced capacity mode in org \`${APIGEE_ORG}\`" \
        --arg details "The following runtime instance(s) in org ${APIGEE_ORG} report a non-normal reduction status:
${reduced}
Capacity may be reduced, limiting throughput for attached environments." \
        --arg severity "3" \
        --arg expected "Instance capacity should be at normal levels." \
        --arg actual "$(count "${reduced}") instance(s) in reduced capacity: $(names "${reduced}")." \
        --arg next_steps "Review the reduction reason for each listed instance and add capacity or resolve the underlying resource constraint." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${no_failover}" ]; then
    issue=$(jq -n \
        --arg title "Apigee environments have no regional failover in org \`${APIGEE_ORG}\`" \
        --arg details "The following environment(s) in org ${APIGEE_ORG} are attached to a single runtime instance:
${no_failover}
If that instance or its region fails, these environments have no automatic failover." \
        --arg severity "4" \
        --arg expected "Production environments should be attached to instances in multiple regions for resilience." \
        --arg actual "$(count "${no_failover}") environment(s) with a single instance: $(names "${no_failover}")." \
        --arg next_steps "Consider attaching each listed environment to an additional runtime instance in another region." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Instance capacity / failover check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
