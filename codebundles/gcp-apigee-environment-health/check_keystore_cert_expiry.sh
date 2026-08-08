#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Keystore Alias Certificate Expiry
#
# For each environment's keystores and truststores, inspects every alias
# certificate and flags any that are expired or will expire within
# CERT_EXPIRY_WARNING_DAYS. Covers both northbound hostname TLS (keystore
# aliases) and southbound target TLS (truststore aliases), which live in
# Apigee-managed keystores outside normal certificate monitoring.
#
# Inspection is restricted to environments that are actually attached to an
# environment group, to avoid false positives from unused environments.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID   - GCP project that owns the Apigee organization
#   APIGEE_ORG       - Apigee org name
#
# OPTIONAL ENV VARS:
#   ENVIRONMENTS              - comma-separated env filter, or 'All'
#   CERT_EXPIRY_WARNING_DAYS  - days before expiry to warn (default 30)
#
# INPUTS:
#   apigee_topology.json  - produced by discover_topology.sh
#
# OUTPUTS:
#   keystore_cert_issues.json - JSON array of issues
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${ENVIRONMENTS:=All}"
: "${CERT_EXPIRY_WARNING_DAYS:=30}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPT_DIR}/apigee_common.sh"

ISSUES_FILE="keystore_cert_issues.json"
issues_json='[]'
now_epoch=$(date +%s)

if [ ! -f "apigee_topology.json" ]; then
    echo "Topology dump missing; run discover_topology.sh first." >&2
    echo "[]" > "${ISSUES_FILE}"
    exit 0
fi

echo "Checking keystore/truststore alias certificate expiry for Apigee org: ${APIGEE_ORG} (warning threshold: ${CERT_EXPIRY_WARNING_DAYS} days)"

# Determine which environments are attached to at least one environment group.
attached_to_group=$(jq -c '[.envgroup_attachments[][]?] | unique' apigee_topology.json)
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

    # Skip environments not attached to any environment group (unused -> no traffic).
    if ! echo "${attached_to_group}" | jq -e --arg e "${env}" 'index($e) != null' >/dev/null 2>&1; then
        echo "  Environment '${env}' is not attached to any environment group; skipping keystore alias inspection."
        continue
    fi
    echo "  Inspecting keystores/truststores for environment '${env}'"

    keystores=$(apigee_get "organizations/${APIGEE_ORG}/environments/${env}/keystores")
    if [ -z "${keystores}" ] || [ "${keystores}" != "["* ]; then
        continue
    fi

    for ks in $(echo "${keystores}" | jq -r '.[]'); do
        ks=$(echo "${ks}" | xargs)
        [ -z "${ks}" ] && continue
        aliases_body=$(apigee_get "organizations/${APIGEE_ORG}/environments/${env}/keystores/${ks}/aliases")
        if [ -z "${aliases_body}" ]; then
            continue
        fi
        # aliases.list returns {"aliases":[{"name":...,"type":...}]}
        aliases=$(echo "${aliases_body}" | jq -c '.aliases // []')
        alias_count=$(echo "${aliases}" | jq 'length')
        if [ -z "${aliases}" ] || [ "${alias_count}" -eq 0 ]; then
            continue
        fi
        echo "    Keystore '${ks}': ${alias_count} alias(es)"

        while read -r alias; do
            alias_name=$(echo "${alias}" | xargs -r basename)
            [ -z "${alias_name}" ] && continue
            alias_detail=$(apigee_get "organizations/${APIGEE_ORG}/environments/${env}/keystores/${ks}/aliases/${alias_name}")
            if [ -z "${alias_detail}" ]; then
                continue
            fi
            expire_time=$(echo "${alias_detail}" | jq -r '.certInfo.expiryDate // ""')
            valid_from=$(echo "${alias_detail}" | jq -r '.certInfo.validFrom // ""')
            subject=$(echo "${alias_detail}" | jq -r '.certInfo.subject // ""')
            type=$(echo "${alias_detail}" | jq -r '.type // ""')
            if [ -z "${expire_time}" ] || [ "${expire_time}" = "null" ]; then
                continue
            fi
            expiry_epoch=$(date -d "${expire_time}" +%s 2>/dev/null || echo "")
            if [ -z "${expiry_epoch}" ]; then
                continue
            fi
            days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
            echo "      Alias '${alias_name}' (${type}) expires ${expire_time} (${days_left} days left)"

            if [ "${days_left}" -le "${CERT_EXPIRY_WARNING_DAYS}" ]; then
                severity="2"
                if [ "${days_left}" -lt 0 ]; then
                    severity="3"
                fi
                issue=$(jq -n \
                    --arg title "Apigee keystore alias certificate \`${alias_name}\` in \`${env}\` expires in ${days_left} days" \
                    --arg details "Alias '${alias_name}' (${type}) in keystore '${ks}' of environment '${env}' (org ${APIGEE_ORG}) has certificate subject '${subject}' expiring at ${expire_time} (${days_left} day(s) remaining). A ${type/truststore/southbound TLS} certificate that expires will break all traffic using it." \
                    --arg severity "${severity}" \
                    --arg expected "All keystore/truststore alias certificates should be valid for more than ${CERT_EXPIRY_WARNING_DAYS} days." \
                    --arg actual "Alias '${alias_name}' in environment '${env}' expires in ${days_left} days (threshold: ${CERT_EXPIRY_WARNING_DAYS})." \
                    --arg next_steps "Replace the certificate for alias '${alias_name}' in keystore '${ks}' of environment '${env}' before it expires, then re-create or update the alias. See gcloud apigee or the Apigee REST API for keystore alias management." \
                    '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}')
                issues_json=$(echo "${issues_json}" | jq --argjson i "${issue}" '. += [$i]')
            fi
        done < <(echo "${aliases}" | jq -r '.[].name')
    done
done

echo "${issues_json}" > "${ISSUES_FILE}"
echo "Keystore certificate expiry check complete. Found $(jq length "${ISSUES_FILE}") issue(s)."
