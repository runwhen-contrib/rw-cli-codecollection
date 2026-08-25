#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Developer App Access Scope
#
# Reviews developer apps and their consumer keys, raising ONE finding PER
# FAILURE MODE, each listing every affected app:
#
#   1. An approved app declaring over-broad / wildcard scopes
#   2. An approved consumer key carrying over-broad / wildcard scopes
#   3. A revoked consumer key still attached to an app
#
# Titles carry the failure mode and the org, never an app name, a developer
# email or a consumer key. Apps and keys come and go, so a per-app title opens
# and closes issues on every run -- and a consumer key is a credential, which
# has no business in an issue title at all. Only a short prefix of a key is
# recorded, in details.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#
# OUTPUTS:
#   app_access_issues.json - JSON array of issue objects
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

OUTPUT_FILE="app_access_issues.json"
issues_json='[]'
broad_app=""
broad_key=""
revoked_key=""

APIGEE_ORG="${APIGEE_ORG#organizations/}"

echo "Checking developer app access scope for org: ${APIGEE_ORG}"

if ! apigee_have_token; then
    # Failure to determine, not a determination of absence.
    jq -n \
        --arg title "Cannot read Apigee developer apps in org \`${APIGEE_ORG}\`" \
        --arg details "Unable to obtain a GCP access token for the Apigee Admin API in project ${GCP_PROJECT_ID}. No developer app was evaluated, so this run determined nothing about access scope." \
        --arg severity "3" \
        --arg expected "Apigee API access should be authenticated." \
        --arg actual "Could not obtain an access token, so no developer app was evaluated." \
        --arg next_steps "Verify the service account is authenticated and has roles/apigee.readOnlyAdmin." \
        '[{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]' \
        > "${OUTPUT_FILE}"
    exit 0
fi

# Both list endpoints are DOCUMENTED, with SINGULAR field names:
#   /developers          -> GoogleCloudApigeeV1ListOfDevelopersResponse {"developer":[...]}
#   /developers/{d}/apps -> GoogleCloudApigeeV1ListDeveloperAppsResponse {"app":[...]}
developers="$(apigee_obj_list "organizations/${APIGEE_ORG}/developers" "developer")"
dev_count="$(echo "${developers}" | jq 'length' 2>/dev/null || echo 0)"

if [ "${dev_count}" -eq 0 ]; then
    # Positive determination of absence -- an org with no developers registered
    # has no app access to get wrong. Not a finding.
    echo "Org '${APIGEE_ORG}' has no registered developers; nothing to evaluate."
    echo "[]" > "${OUTPUT_FILE}"
    exit 0
fi

# Wildcard-ish scopes. Kept as one pattern so the app-level and key-level checks
# cannot drift apart.
is_broad() {
    echo "$1" | jq -e 'map(select(test("\\*"))) | length > 0' >/dev/null 2>&1
}

while IFS= read -r dev_obj; do
    [ -z "${dev_obj}" ] && continue
    dev_email="$(echo "${dev_obj}" | jq -r '.email // .developerId // empty')"
    [ -z "${dev_email}" ] && continue

    apps="$(apigee_obj_list "organizations/${APIGEE_ORG}/developers/${dev_email}/apps" "app")"
    [ "$(echo "${apps}" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ] && continue

    while IFS= read -r app_ref; do
        [ -z "${app_ref}" ] && continue
        app_name="$(echo "${app_ref}" | jq -r '.name // empty')"
        [ -z "${app_name}" ] && continue

        app="$(apigee_get "organizations/${APIGEE_ORG}/developers/${dev_email}/apps/${app_name}")"
        [ -z "${app}" ] && continue
        app_status="$(echo "${app}" | jq -r '.status // empty')"
        app_scopes="$(echo "${app}" | jq -c '.scopes // []')"
        credentials="$(echo "${app}" | jq -c '.credentials // []')"

        echo "  Developer '${dev_email}' app '${app_name}' (status=${app_status})"

        if [ "${app_status}" = "approved" ] || [ -z "${app_status}" ]; then
            if is_broad "${app_scopes}"; then
                broad_app="${broad_app}  - ${app_name} (developer ${dev_email}): scopes ${app_scopes}
"
            fi
        fi

        while IFS= read -r cred; do
            [ -z "${cred}" ] && continue
            consumer_key="$(echo "${cred}" | jq -r '.consumerKey // empty')"
            cred_status="$(echo "${cred}" | jq -r '.status // empty')"
            cred_scopes="$(echo "${cred}" | jq -c '.scopes // []')"

            # Only a short prefix, never the whole key: this string lands in an
            # issue body.
            key_hint="${consumer_key:0:8}"
            echo "    Consumer key ${key_hint}... status=${cred_status}"

            if [ "${cred_status}" = "approved" ] && is_broad "${cred_scopes}"; then
                broad_key="${broad_key}  - ${app_name} (developer ${dev_email}, key ${key_hint}...): scopes ${cred_scopes}
"
            fi
            if [ "${cred_status}" = "revoked" ]; then
                revoked_key="${revoked_key}  - ${app_name} (developer ${dev_email}, key ${key_hint}...)
"
            fi
        done < <(echo "${credentials}" | jq -c '.[]')
    done < <(echo "${apps}" | jq -c '.[]')
done < <(echo "${developers}" | jq -c '.[]')

# The accumulator lines carry "name (developer ...)", so trim at the paren.
app_names() { printf '%s' "$1" | sed 's/^  - //; s/ (.*//' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g'; }

if [ -n "${broad_app}" ]; then
    issue=$(jq -n \
        --arg title "Apigee developer apps declare over-broad scopes in org \`${APIGEE_ORG}\`" \
        --arg details "The following approved developer app(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) declare wildcard scopes:
${broad_app}
Each may reach APIs well beyond what it needs." \
        --arg severity "3" \
        --arg expected "Developer apps should request only the specific scopes they need." \
        --arg actual "$(count_lines "${broad_app}") app(s) with wildcard scopes: $(app_names "${broad_app}")." \
        --arg next_steps "Reduce each listed app's scopes to the minimum necessary, and rotate its consumer key if the over-broad scope was ever active." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${broad_key}" ]; then
    issue=$(jq -n \
        --arg title "Apigee consumer keys carry over-broad scopes in org \`${APIGEE_ORG}\`" \
        --arg details "The following approved consumer key(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) carry wildcard scopes:
${broad_key}
An approved key with wildcard scope is a live credential with more access than it needs. Keys are identified by an 8-character prefix only." \
        --arg severity "3" \
        --arg expected "Approved consumer keys should carry least-privilege scopes." \
        --arg actual "$(count_lines "${broad_key}") key(s) with wildcard scopes, on app(s): $(app_names "${broad_key}")." \
        --arg next_steps "Revoke and re-issue each listed consumer key with scoped permissions, or narrow the owning app's scopes to the minimum required." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

if [ -n "${revoked_key}" ]; then
    issue=$(jq -n \
        --arg title "Revoked Apigee consumer keys are still attached to apps in org \`${APIGEE_ORG}\`" \
        --arg details "The following revoked consumer key(s) in org ${APIGEE_ORG} (project ${GCP_PROJECT_ID}) remain attached to their app:
${revoked_key}
Revoked keys do not grant access, but leaving them attached enlarges the attack surface if one is ever re-approved by mistake. Keys are identified by an 8-character prefix only." \
        --arg severity "2" \
        --arg expected "Consumer keys should be removed once they are no longer needed." \
        --arg actual "$(count_lines "${revoked_key}") revoked key(s) still attached, on app(s): $(app_names "${revoked_key}")." \
        --arg next_steps "Delete each listed revoked consumer key from its app, or delete the app entirely if it is no longer in use." \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
    issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
fi

echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Developer app access check complete. Found $(jq length "${OUTPUT_FILE}") issue(s)."
