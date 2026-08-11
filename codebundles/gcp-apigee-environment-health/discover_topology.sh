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
# Accept either "my-org" or "organizations/my-org"; the REST paths below supply
# the "organizations/" prefix themselves.
APIGEE_ORG="${APIGEE_ORG#organizations/}"
if [ -n "${APIGEE_ORG}" ]; then
    echo "Using APIGEE_ORG=${APIGEE_ORG}"
else
    echo "APIGEE_ORG not set; discovering Apigee organization(s) in project ${GCP_PROJECT_ID}"

    # INTERIM (remove once the generation rule can gate on an Apigee resource
    # type -- see .runwhen/generation-rules/ for the note). The rule currently
    # matches every indexed project, so this script runs against projects that
    # have never used Apigee. Reporting those as failures makes most SLXs in a
    # workspace permanently red. (The bundle is runbook-only, so this now keeps
    # those projects from raising issues rather than from scoring 0.)
    #
    # The distinction that makes this safe is POSITIVE DETERMINATION OF ABSENCE
    # versus FAILURE TO DETERMINE. "The API answered and there is no org here"
    # and "the Apigee API is not enabled on this project" are both definite
    # answers: Apigee is not in use. Anything else -- denied, unreachable,
    # unparseable -- means we could not tell, and must still fail loudly, or we
    # are back to reporting healthy while blind.
    list_body="$(mktemp)"
    list_code=$(apigee_probe "organizations" "${list_body}")
    list="$(cat "${list_body}")"
    rm -f "${list_body}"

    not_applicable=""
    case "${list_code}" in
        200)
            APIGEE_ORG=$(echo "${list}" | jq -r '
                if type == "array" then
                    (map(.name)[] | split("/") | .[-1] | select(. != "")) // ""
                else
                    (.organizations // [] | map(.organization)[] | split("/") | .[-1] | select(. != "")) // ""
                end' 2>/dev/null | head -n1)
            [ -z "${APIGEE_ORG}" ] && not_applicable="the Apigee API is enabled but project ${GCP_PROJECT_ID} has no Apigee organization"
            ;;
        403|404)
            # SERVICE_DISABLED means the Apigee API was never enabled here, so
            # no organization can exist. A plain permission denial is NOT that.
            if echo "${list}" | grep -qiE 'SERVICE_DISABLED|has not been used in project|accessNotConfigured|API has not been used'; then
                not_applicable="the Apigee API is not enabled on project ${GCP_PROJECT_ID}"
            fi
            ;;
    esac

    if [ -n "${not_applicable}" ]; then
        # A well-formed empty topology, not "{}": downstream checks then read
        # real empty collections instead of nulls.
        jq -n --arg project "${GCP_PROJECT_ID}" --arg reason "${not_applicable}" \
            '{org: {applicable: false, reason: $reason, project: $project},
              environments: [], instances: [], envgroups: [],
              envgroup_attachments: {}, instance_attachments: {}}' > "${TOPOLOGY_FILE}"
        echo "[]" > "${ISSUES_FILE}"
        echo "NOT APPLICABLE: ${not_applicable}."
        echo "Nothing to score for this project; wrote an empty topology."
        exit 0
    fi

    if [ -z "${APIGEE_ORG}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg title "Cannot determine the Apigee organization for this project" \
            --arg details "Listing Apigee organizations returned HTTP ${list_code} and the response could not be read as an organization list. This is NOT the same as the project having no Apigee organization -- that case is detected separately and reported as not applicable. Confirm the service account has apigee.organizations.list." \
            --arg severity "4" \
            --arg expected "The Apigee organizations visible to this service account should be retrievable." \
            --arg actual "organizations list returned HTTP ${list_code}." \
            --arg next_steps "Verify the service account has roles/apigee.readOnlyAdmin, then re-run. If project ${GCP_PROJECT_ID} genuinely does not use Apigee, the check reports not applicable instead." \
            '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
        echo "${issues_json}" > "${ISSUES_FILE}"
        echo "{}" > "${TOPOLOGY_FILE}"
        echo "Organization discovery failed (HTTP ${list_code}). Issues written to ${ISSUES_FILE}"
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
        --arg title "Cannot access the Apigee organization" \
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
# `[ "$x" != "["* ]` does NOT pattern-match inside test; use case so a real JSON
# array is kept instead of being silently discarded.
case "${environments_raw}" in
    \[*) ;;
    *) environments_raw="[]" ;;
esac
env_names=$(echo "${environments_raw}" | jq -r '.[]?')

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
    # Envgroup attachments come back under environmentGroupAttachments, NOT
    # attachments -- unlike instance attachments above, which do use
    # "attachments". Reading the wrong field made every attached envgroup look
    # orphaned.
    att=$(apigee_list_field "organizations/${APIGEE_ORG}/envgroups/${eg_name}/attachments" "environmentGroupAttachments")
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
# The runtime VPC is Organization.authorizedNetwork; there is no networkConfig
# on an Apigee org, so the old .networkConfig.network read always came back
# empty and every healthy org looked like it had no network. Keep the old path
# as a fallback for any surface that does return it.
network=$(echo "${org}" | jq -r '.authorizedNetwork // .networkConfig.network // ""' | xargs -r basename)
# peeringCidrRange is a per-INSTANCE field, not an org field. Report the
# distinct ranges actually in use across the runtime instances.
peering_range=$(echo "${instances_json}" | jq -r '[.[].peeringCidrRange // empty] | unique | join(", ")')
# Orgs created without VPC peering (disableVpcPeering=true) intentionally have
# no authorizedNetwork; that is a valid topology, not a misconfiguration.
vpc_peering_disabled=$(echo "${org}" | jq -r 'if has("disableVpcPeering") then .disableVpcPeering else false end')

jq -n \
    --arg org "${APIGEE_ORG}" \
    --arg project "${GCP_PROJECT_ID}" \
    --arg org_state "${org_state}" \
    --arg runtime_type "${runtime_type}" \
    --arg network "${network}" \
    --arg peering_range "${peering_range}" \
    --argjson vpc_peering_disabled "${vpc_peering_disabled}" \
    --argjson org_raw "${org}" \
    --argjson instances "${instances_json}" \
    --argjson envgroups "${envgroups_json}" \
    --argjson environments "${envs_enriched}" \
    --argjson envgroup_attachments "${envgroup_attachments}" \
    --argjson instance_attachments "${instance_attachments}" \
    '{org: {name:$org, project:$project, state:$org_state, runtime_type:$runtime_type, network:$network, peering_cidr_range:$peering_range, vpc_peering_disabled:$vpc_peering_disabled, raw:$org_raw},
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
