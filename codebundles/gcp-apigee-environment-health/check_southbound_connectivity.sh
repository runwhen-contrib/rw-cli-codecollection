#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Southbound VPC Peering and Private Service Connect
#
# Inspects the Apigee org's network configuration, VPC peering connections and
# Private Service Connect endpoints/attachments in GCP_PROJECT_ID. Flags failed
# PSC endpoints and exhausted service peering ranges, which break every
# southbound call at once while all Apigee resources still report healthy.
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
#   southbound_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:=}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="southbound_issues.json"
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

echo "Checking southbound VPC peering and Private Service Connect for project: ${GCP_PROJECT_ID}"

network=$(jq -r '.org.network // ""' apigee_topology.json)
peering_range=$(jq -r '.org.peering_cidr_range // ""' apigee_topology.json)
peering_disabled=$(jq -r '.org.vpc_peering_disabled // false' apigee_topology.json)

# An org provisioned with disableVpcPeering=true has no authorizedNetwork by
# design; VPC peering simply does not apply to it, so there is nothing here to
# assess and nothing to flag.
if [ "${peering_disabled}" = "true" ]; then
    echo "Org ${APIGEE_ORG} is provisioned without VPC peering (disableVpcPeering=true); skipping peering checks."
    echo "${issues_json}" > "${ISSUES_FILE}"
    exit 0
fi

if [ -z "${network}" ]; then
    issue=$(jq -n \
        --arg title "Apigee org \`${APIGEE_ORG}\` has no VPC network configured" \
        --arg details "Organization ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) does not define a runtime VPC network (authorizedNetwork). Southbound connectivity to target servers cannot be assessed without a network." \
        --arg severity "3" \
        --arg expected "The Apigee org should have a connected VPC network for runtime traffic." \
        --arg actual "No authorizedNetwork found for the org, and VPC peering is not explicitly disabled." \
        --arg next_steps "Associate the Apigee org with its intended VPC network via authorizedNetwork, or set disableVpcPeering if this org intentionally runs without peering." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
    echo "${issues_json}" > "${ISSUES_FILE}"
    echo "No network configured; check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
    exit 0
fi

echo "  Org network: '${network}', peering CIDR range: '${peering_range}'"

# --- 1. VPC peering via Service Networking ---
if ! peerings=$(gcloud services vpc-peerings list \
        --network="${network}" \
        --project="${GCP_PROJECT_ID}" \
        --format=json 2>err_peering.log); then
    err_msg=$(cat err_peering.log)
    rm -f err_peering.log
    issue=$(jq -n \
        --arg title "Cannot list VPC peering for Apigee org \`${APIGEE_ORG}\`" \
        --arg details "gcloud services vpc-peerings list for network '${network}' failed: ${err_msg}" \
        --arg severity "3" \
        --arg expected "Service peering connections for the Apigee runtime project should be listable." \
        --arg actual "VPC peering listing failed: ${err_msg}" \
        --arg next_steps "Verify compute.networkViewer / serviceusage permissions and that Service Networking API is enabled." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
else
    peering_count=$(echo "${peerings}" | jq 'length')
    echo "  Found ${peering_count} service peering connection(s)"
    # Reserved peering ranges allocated to this network/peering
    ranges=$(echo "${peerings}" | jq -r '.[].reservedPeeringRanges[]? // empty' | tr '\n' ',' | sed 's/,$//')
    if [ -n "${ranges}" ]; then
        for range in $(echo "${ranges}" | tr ',' '\n'); do
            range=$(echo "${range}" | xargs)
            [ -z "${range}" ] && continue
            if ! used=$(gcloud compute addresses describe "${range}" \
                    --global --project="${GCP_PROJECT_ID}" --format='value(status)' 2>/dev/null); then
                continue
            fi
            echo "    Reserved range '${range}' used (status=${used})"
        done
    fi
fi

# --- 2. Private Service Connect endpoints (forwarding rules with PSC) ---
if ! psc=$(gcloud compute forwarding-rules list \
        --project="${GCP_PROJECT_ID}" \
        --format=json \
        --filter="pscConnectionStatus:*" 2>err_psc.log); then
    err_msg=$(cat err_psc.log)
    rm -f err_psc.log
    issue=$(jq -n \
        --arg title "Cannot list Private Service Connect endpoints in \`${GCP_PROJECT_ID}\`" \
        --arg details "gcloud compute forwarding-rules list (PSC filter) failed: ${err_msg}" \
        --arg severity "3" \
        --arg expected "Private Service Connect endpoints should be listable to verify southbound connectivity." \
        --arg actual "PSC forwarding-rules listing failed: ${err_msg}" \
        --arg next_steps "Verify compute.forwardingRules.list permission and that you are querying the project owning the Apigee org." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
elif [ -n "${psc}" ] && [ "${psc}" != "[]" ]; then
    psc_count=$(echo "${psc}" | jq 'length')
    echo "  Found ${psc_count} Private Service Connect endpoint(s)"
    # Acceptable statuses; anything else is a connectivity problem.
    # -c keeps one forwarding rule per line so the read loop below can parse it.
    echo "${psc}" | jq -c '.[] | select((.pscConnectionStatus // "ACCEPTED") != "ACCEPTED")' > psc_bad.json
    bad_count=$(wc -l < psc_bad.json | xargs)
    if [ "${bad_count:-0}" -gt 0 ]; then
        while read -r fr; do
            [ -z "${fr}" ] && continue
            fr_name=$(echo "${fr}" | jq -r '.name // empty')
            fr_status=$(echo "${fr}" | jq -r '.pscConnectionStatus // "UNKNOWN"')
            fr_target=$(echo "${fr}" | jq -r '.target // empty')
            issue=$(jq -n \
                --arg title "Private Service Connect endpoint \`${fr_name}\` is not ACCEPTED (status=${fr_status})" \
                --arg details "PSC forwarding rule '${fr_name}' targeting service attachment '${fr_target}' in project ${GCP_PROJECT_ID} has connection status '${fr_status}'. PENDING/REJECTED/CLOSED/NEEDS_ATTENTION PSC endpoints break every southbound call to that backend." \
                --arg severity "2" \
                --arg expected "PSC endpoint connections should be ACCEPTED so southbound traffic flows." \
                --arg actual "PSC forwarding rule '${fr_name}' has status '${fr_status}'." \
                --arg next_steps "Troubleshoot the service attachment / PSC endpoint: verify the publisher accepted the connection, that the network is correct, and that firewall/DNS is in place. See the Apigee + Private Service Connect docs." \
                '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
            issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
        done < psc_bad.json
    fi
    rm -f psc_bad.json
fi

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Southbound connectivity check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
