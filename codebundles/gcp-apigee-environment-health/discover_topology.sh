#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover Apigee Organization, Environments, Instances and Env Groups
#
# Uses org-wide REST endpoints to build ONE config dump of the org topology:
#   - organizations/{org}                          organization details
#   - organizations/{org}/environments             list
#   - organizations/{org}/instances                list + per-instance state
#   - organizations/{org}/envgroups                list + hostnames
#   - organizations/{org}/envgroups/{eg}/attachments
#   - organizations/{org}/instances/{i}/attachments
#
# The dump serves as the input for all downstream tasks. The org name is taken
# from APIGEE_ORG, or discovered by listing the project's Apigee organizations.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that owns the Apigee organization
#   APIGEE_ORG       - Apigee org name (optional; discovered if empty)
#
# OUTPUTS:
#   apigee_topology.json      - enriched org topology dump
#   discovery_issues.json     - JSON array of issues (usually empty on success)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

TOPOLOGY_FILE="apigee_topology.json"
ISSUES_FILE="discovery_issues.json"
issues_json='[]'

# Resolve the Apigee org from APIGEE_ORG or discover it in the project.
if [ -n "${APIGEE_ORG}" ]; then
    echo "Using APIGEE_ORG=${APIGEE_ORG}"
else
    echo "APIGEE_ORG not set; discovering Apigee organization(s) in project ${GCP_PROJECT_ID}"
    list=$(apigee_get "organizations")
    if [ -z "${list}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg title "Cannot list Apigee organizations for project \`${GCP_PROJECT_ID}\`" \
            --arg details "The organizations list endpoint returned no data. Confirm the service account has apigee.organizations.list and that the Apigee API is enabled." \
            --arg severity "4" \
            --arg expected "The Apigee organizations in project ${GCP_PROJECT_ID} should be retrievable." \
            --arg actual "organizations list returned no data." \
            --arg next_steps "Verify the service account has roles/apigee.readOnlyAdmin and the Apigee API is enabled for the project." \
            '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
        echo "${issues_json}" > "${ISSUES_FILE}"
        echo "{}" > "${TOPOLOGY_FILE}"
        echo "Organization discovery failed. Issues written to ${ISSUES_FILE}"
        exit 0
    fi
    APIGEE_ORG=$(echo "${list}" | jq -r --arg pid "${GCP_PROJECT_ID}" '
        if type == "array" then
            (map(.name)[] | split("/") | .[-1] | select(. != "")) // ""
        else
            (.organizations // [] | map(.organization)[] | split("/") | .[-1] | select(. != "")) // ""
        end' | head -n1)
    if [ -z "${APIGEE_ORG}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg title "No Apigee organization found in project \`${GCP_PROJECT_ID}\`" \
            --arg details "No Apigee organization could be discovered for project ${GCP_PROJECT_ID}." \
            --arg severity "3" \
            --arg expected "There is at least one Apigee organization in the project." \
            --arg actual "No Apigee organization found." \
            --arg next_steps "Provision an Apigee organization or set APIGEE_ORG explicitly." \
            '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
        echo "${issues_json}" > "${ISSUES_FILE}"
        echo "{}" > "${TOPOLOGY_FILE}"
        echo "No Apigee organization discovered. Issues written to ${ISSUES_FILE}"
        exit 0
    fi
    echo "Discovered Apigee org: ${APIGEE_ORG}"
fi

echo "Discovering topology for Apigee org: ${APIGEE_ORG}"

# --- Organization details ---
org="{}"
if ! org=$(apigee_get "organizations/${APIGEE_ORG}"); then
    org="{}"
fi
if [ -z "${org}" ] || [ "${org}" = "{}" ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg title "Cannot access Apigee organization \`${APIGEE_ORG}\`" \
        --arg details "GET organizations/${APIGEE_ORG} returned no data. Confirm the org name and the service account permissions (roles/apigee.readOnlyAdmin)." \
        --arg severity "4" \
        --arg expected "The Apigee organization ${APIGEE_ORG} should be retrievable." \
        --arg actual "GET organizations/${APIGEE_ORG} returned no data." \
        --arg next_steps "Verify APIGEE_ORG is correct, the Apigee API is enabled, and the service account has apigee.organizations.get." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "${issues_json}" > "${ISSUES_FILE}"
    echo "{}" > "${TOPOLOGY_FILE}"
    echo "Organization access failed. Issues written to ${ISSUES_FILE}"
    exit 0
fi

# --- Environments (one org-wide call, returns an array of names) ---
environments_raw="[]"
environments_raw=$(apigee_get "organizations/${APIGEE_ORG}/environments")
[ -z "${environments_raw}" ] && environments_raw="[]"
[ "${environments_raw}" != "["* ] && environments_raw="[]"
env_names=$(echo "${environments_raw}" | jq -r '.[]')

# --- Instances (org-wide list with state/hostname) ---
instances_json="[]"
instances_json=$(apigee_list_field "organizations/${APIGEE_ORG}/instances" "instances")
[ -z "${instances_json}" ] && instances_json="[]"

# --- Environment groups (org-wide list with hostnames + state) ---
envgroups_json="[]"
envgroups_json=$(apigee_list_field "organizations/${APIGEE_ORG}/envgroups" "environmentGroups")
[ -z "${envgroups_json}" ] && envgroups_json="[]"

# --- Per-instance attachments (map env -> list of instances) ---
instance_attachments='{}'
while read -r inst; do
    inst_name=$(echo "${inst}" | jq -r '.name // empty' | xargs -r basename)
    [ -z "${inst_name}" ] && continue
    att=$(apigee_list_field "organizations/${APIGEE_ORG}/instances/${inst_name}/attachments" "attachments")
    [ -z "${att}" ] && att="[]"
    envs=$(echo "${att}" | jq -c '[.[] | .environment // empty]')
    instance_attachments=$(echo "${instance_attachments}" | jq --arg i "${inst_name}" --argjson e "${envs}" '. + {($i): $e}')
done < <(echo "${instances_json}" | jq -c '.[]')

# --- Per-envgroup attachments (map envgroup -> list of environments) ---
envgroup_attachments='{}'
while read -r eg; do
    eg_name=$(echo "${eg}" | jq -r '.name // empty' | xargs -r basename)
    [ -z "${eg_name}" ] && continue
    att=$(apigee_list_field "organizations/${APIGEE_ORG}/envgroups/${eg_name}/attachments" "attachments")
    [ -z "${att}" ] && att="[]"
    envs=$(echo "${att}" | jq -c '[.[] | .environment // empty]')
    envgroup_attachments=$(echo "${envgroup_attachments}" | jq --arg e "${eg_name}" --argjson e2 "${envs}" '. + {($e): $e2}')
done < <(echo "${envgroups_json}" | jq -c '.[]')

# --- Build enriched env list with instance attachments per env ---
envs_enriched='[]'
while IFS= read -r env; do
    [ -z "${env}" ] && continue
    # Instances whose attachment list contains this environment
    attached_instances=$(echo "${instance_attachments}" | jq -c --arg e "${env}" '[to_entries[] | select(.value | index($e)) | .key]')
    envs_enriched=$(echo "${envs_enriched}" | jq --arg e "${env}" --argjson ai "${attached_instances}" '. + [{"name":$e,"attached_instances":$ai}]')
done <<< "${env_names}"

# --- Build final topology dump ---
org_state=$(echo "${org}" | jq -r '.state // ""')
runtime_type=$(echo "${org}" | jq -r '.runtimeType // ""')
network=$(echo "${org}" | jq -r '.networkConfig.network // ""' | xargs -r basename)
peering_range=$(echo "${org}" | jq -r '.networkConfig.peeringCidrRange // ""')

jq -n \
    --arg org "${APIGEE_ORG}" \
    --arg project "${GCP_PROJECT_ID}" \
    --arg org_state "${org_state}" \
    --arg runtime_type "${runtime_type}" \
    --arg network "${network}" \
    --arg peering_range "${peering_range}" \
    --argjson org_raw "${org}" \
    --argjson instances "${instances_json}" \
    --argjson envgroups "${envgroups_json}" \
    --argjson environments "${envs_enriched}" \
    --argjson envgroup_attachments "${envgroup_attachments}" \
    --argjson instance_attachments "${instance_attachments}" \
    '{org: {name:$org, project:$project, state:$org_state, runtime_type:$runtime_type, network:$network, peering_cidr_range:$peering_range, raw:$org_raw},
      environments: $environments,
      instances: $instances,
      envgroups: $envgroups,
      envgroup_attachments: $envgroup_attachments,
      instance_attachments: $instance_attachments}' > "${TOPOLOGY_FILE}"

echo "Discovered org state=${org_state}, runtime=${runtime_type}, network=${network}, peering_range=${peering_range}"
echo "Environments: $(echo "${envs_enriched}" | jq -r '.[].name' | tr '\n' ', ' | sed 's/,$//')"
echo "Instances: $(echo "${instances_json}" | jq -r '[.[].name] | join(", ")')"
echo "Env groups: $(echo "${envgroups_json}" | jq -r '[.[].name] | join(", ")')"

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Topology dump written to ${TOPOLOGY_FILE}"
cat "${TOPOLOGY_FILE}"
