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
#   APIGEE_ORG       - Apigee org name
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
: "${APIGEE_ORG:?Must set APIGEE_ORG}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="capacity_issues.json"
issues_json='[]'

if [ ! -f "apigee_topology.json" ]; then
    echo "Topology dump missing; run discover_topology.sh first." >&2
    echo "[]" > "${ISSUES_FILE}"
    exit 0
fi

echo "Checking instance capacity and regional failover for Apigee org: ${APIGEE_ORG}"

instances_total=$(jq '[.instances[]?] | length' apigee_topology.json)
if [ "${instances_total}" -eq 0 ]; then
    issue=$(jq -n \
        --arg title "Apigee org \`${APIGEE_ORG}\` has no runtime instances" \
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
        severity="3"
        if [ "${inst_state}" = "CREATING" ] || [ "${inst_state}" = "UPDATING" ]; then
            severity="2"
        fi
        issue=$(jq -n \
            --arg title "Apigee runtime instance \`${inst_name}\` is not ACTIVE (state=${inst_state})" \
            --arg details "Runtime instance '${inst_name}' at ${inst_location} in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) has state '${inst_state}'. Every environment attached to this instance cannot be served." \
            --arg severity "${severity}" \
            --arg expected "Runtime instances should be in ACTIVE state." \
            --arg actual "Instance '${inst_name}' state is '${inst_state}'." \
            --arg next_steps "Wait for CREATING/UPDATING to complete, or investigate a FAILED instance and recreate it via the Apigee UI/REST." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
    fi

    # Capacity (CPU) via asyncRuntime entity; degrade gracefully if unavailable.
    cap_body=$(apigee_get "organizations/${APIGEE_ORG}/instances/${inst_name}?entity=asyncRuntime")
    if [ -n "${cap_body}" ]; then
        cap_units_total=$(echo "${cap_body}" | jq -r '.capacityUnits // empty')
        cap_units_used=$(echo "${cap_body}" | jq -r '.usageInfo.capacityUnitsUsed // empty')
        reduction=$(echo "${cap_body}" | jq -r '.reductionStatus.status // ""')
        echo "    capacityUnits=${cap_units_total} used=${cap_units_used} reduction=${reduction}"
        if [ -n "${reduction}" ] && [ "${reduction}" != "" ] && [ "${reduction}" != "NORMAL" ]; then
            issue=$(jq -n \
                --arg title "Apigee runtime instance \`${inst_name}\` is in reduced capacity mode (${reduction})" \
                --arg details "Instance '${inst_name}' in org ${APIGEE_ORG} reports reduction status '${reduction}'; capacity may be reduced, limiting throughput for attached environments." \
                --arg severity "3" \
                --arg expected "Instance capacity should be at normal levels." \
                --arg actual "Instance '${inst_name}' reduction status is '${reduction}'." \
                --arg next_steps "Review the reduction reason and add capacity or resolve the underlying resource constraint." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
        fi
    fi
done < <(jq -c '.instances[]' apigee_topology.json)

# --- Regional failover posture per environment ---
while read -r env; do
    env_name=$(echo "${env}" | jq -r '.name // empty')
    [ -z "${env_name}" ] && continue
    attached=$(echo "${env}" | jq -r '[.attached_instances[]?] | length')
    unique_locations=$(echo "${env}" | jq -r --argjson instlist "$(jq -c '.instances' apigee_topology.json)" '
        [ .attached_instances[]? as $n | $instlist[] | select(.name | endswith("/"+$n)) | .location // "" ] | unique | length')
    if [ "${attached:-0}" -eq 1 ]; then
        issue=$(jq -n \
            --arg title "Apigee environment \`${env_name}\` is served by a single runtime instance (no regional failover)" \
            --arg details "Environment '${env_name}' in org ${APIGEE_ORG} is attached to only ${attached} runtime instance(s) spanning ${unique_locations} region(s). If that instance/region fails, this environment has no automatic failover." \
            --arg severity "4" \
            --arg expected "Production environments should be attached to instances in multiple regions for resilience." \
            --arg actual "Environment '${env_name}' has ${attached} instance attachment(s) across ${unique_locations} region(s)." \
            --arg next_steps "Consider attaching the environment to an additional runtime instance in another region to provide failover." \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
        issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
        echo "  Environment '${env_name}' has no failover (single instance/region)"
    else
        echo "  Environment '${env_name}' attached to ${attached} instance(s) across ${unique_locations} region(s)"
    fi
done < <(jq -c '.environments[]' apigee_topology.json)

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Instance capacity / failover check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
