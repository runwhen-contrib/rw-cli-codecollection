#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Target Server TLS Configuration
#
# Reviews every target server in every environment and raises ONE finding
# listing each one that carries no TLS (sSLInfo), i.e. a plaintext backend.
#
# The title carries the failure mode and the org, never a target server name --
# target servers come and go, so a per-target title opens and closes issues on
# every run. The names live in details/actual.
#
# RESPONSE SHAPE -- the defect this script shipped with.
#
# organizations/{org}/environments and .../environments/{env}/targetservers have
# NO entry in the Apigee v1 discovery document and return a BARE ARRAY OF
# STRINGS. This script used to read `.name`, `.host` and `.sSLInfo` off each
# element of that array -- i.e. off a STRING -- so jq errored, every field came
# back empty, and the `[ -z "$ssl_enabled" ]` test then fired for EVERY target
# server in the org. It reported a plaintext backend for each one whether or not
# TLS was configured, while never having read a single target server document.
#
# The list endpoint returns names only; the TLS configuration lives on the
# per-target-server GET, which is documented
# (apigee.organizations.environments.targetservers.get ->
# GoogleCloudApigeeV1TargetServer) and does carry sSLInfo. So each target server
# has to be fetched individually.
#
# Virtual hosts have no public REST list endpoint on Apigee X at all, so there is
# nothing to enumerate; their absence is not a finding and is not reported.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#
# OUTPUTS:
#   target_vhost_issues.json - JSON array of issue objects
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

OUTPUT_FILE="target_vhost_issues.json"
issues_json='[]'
plaintext=""

APIGEE_ORG="${APIGEE_ORG#organizations/}"

echo "Checking target server TLS configuration for org: ${APIGEE_ORG}"

if [ -z "$(apigee_token)" ]; then
    # Failure to determine, not a determination of absence.
    jq -n \
        --arg title "Cannot read Apigee target servers in org \`${APIGEE_ORG}\`" \
        --arg details "Unable to obtain a GCP access token for the Apigee Admin API in project ${GCP_PROJECT_ID}. No target server was evaluated, so this run determined nothing about backend TLS." \
        --arg severity "3" \
        --arg expected "Apigee API access should be authenticated." \
        --arg actual "Could not obtain an access token, so no target server was evaluated." \
        --arg next_steps "Verify the service account is authenticated and has roles/apigee.readOnlyAdmin." \
        '[{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]' \
        > "${OUTPUT_FILE}"
    exit 0
fi

environments="$(apigee_str_list "organizations/${APIGEE_ORG}/environments")"
if [ -z "${environments}" ]; then
    # Positive determination of absence -- not a finding.
    echo "Org '${APIGEE_ORG}' has no environments; nothing to evaluate."
    echo "[]" > "${OUTPUT_FILE}"
    exit 0
fi

while IFS= read -r env_name; do
    [ -z "${env_name}" ] && continue
    echo "  Checking environment '${env_name}'"

    ts_names="$(apigee_str_list "organizations/${APIGEE_ORG}/environments/${env_name}/targetservers")"
    if [ -z "${ts_names}" ]; then
        echo "    No target servers in environment '${env_name}'"
        continue
    fi

    while IFS= read -r ts_name; do
        [ -z "${ts_name}" ] && continue
        # The TLS configuration is only on the per-target-server document; the
        # list endpoint returns names.
        ts="$(apigee_get "organizations/${APIGEE_ORG}/environments/${env_name}/targetservers/${ts_name}")"
        if [ -z "${ts}" ]; then
            echo "    Target server '${ts_name}' could not be read; skipping"
            continue
        fi
        ts_host="$(echo "${ts}" | jq -r '.host // ""')"
        ts_port="$(echo "${ts}" | jq -r '.port // ""')"
        # `.sSLInfo.enabled // false` would report an explicitly DISABLED TLS
        # config the same as an absent one, which is fine here (both are
        # plaintext), but `.enabled` must be read only when sSLInfo is an object
        # -- jq errors on indexing a null with a name under some versions.
        ssl_enabled="$(echo "${ts}" | jq -r 'if (.sSLInfo | type) == "object" and (.sSLInfo | has("enabled")) then .sSLInfo.enabled else false end')"

        echo "    Target server '${ts_name}': host=${ts_host}:${ts_port} sSLInfo.enabled=${ssl_enabled}"

        if [ "${ssl_enabled}" != "true" ]; then
            plaintext="${plaintext}  - ${ts_name} in environment ${env_name} -> ${ts_host}:${ts_port}
"
        fi
    done <<< "${ts_names}"
done <<< "${environments}"

names() { printf '%s' "$1" | sed 's/^  - //; s/ in environment.*//' | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }

if [ -n "${plaintext}" ]; then
    issue=$(jq -n \
        --arg title "Apigee target servers are not TLS-enabled in org \`${APIGEE_ORG}\`" \
        --arg details "The following target server(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) have no TLS configured (sSLInfo.enabled is false or absent):
${plaintext}
Traffic from the Apigee runtime to these backends is unencrypted, exposing anything sensitive in the request or response in transit." \
        --arg severity "3" \
        --arg expected "Every target server should use TLS (sSLInfo.enabled = true) to encrypt southbound traffic." \
        --arg actual "$(count_lines "${plaintext}") target server(s) without TLS: $(names "${plaintext}")." \
        --arg next_steps "Enable TLS on each listed target server by configuring a keystore/truststore in its sSLInfo, or confirm a load balancer inside the trust boundary terminates TLS in front of it." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Target server TLS check complete. Found $(jq length "${OUTPUT_FILE}") issue(s)."
