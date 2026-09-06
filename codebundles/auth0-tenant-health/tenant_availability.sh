#!/usr/bin/env bash
set -euo pipefail
set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AUTH0_TENANT            (e.g. mytenant)
#   AUTH0_MGMT_CREDENTIALS  (JSON client_id/client_secret OR raw MAPI token)
#
# This script verifies the Auth0 tenant is reachable and operational by:
#   1) Resolving the tenant domain DNS and querying the well-known discovery
#      endpoint (https://<tenant>.auth0.com/.well-known/openid-configuration)
#   2) Confirming the discovery document advertises /authorize and /userinfo
#   3) Confirming a non-5xx response from the Management API path
# Outputs a JSON array of issues to OUTPUT_FILE.
# -----------------------------------------------------------------------------

: "${AUTH0_TENANT:?Must set AUTH0_TENANT}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/auth0_helpers.sh"

OUTPUT_FILE="tenant_availability_issues.json"
issues_json='[]'

echo "Checking Auth0 tenant service availability for tenant: ${AUTH0_TENANT}"
echo "Tenant base URL: ${AUTH0_BASE_URL}"

# --- 1. DNS resolution of the tenant domain ---
if ! host_resolved="$(getent hosts "${AUTH0_DOMAIN}" 2>/dev/null || true)"; then
    host_resolved=""
fi
if [ -z "${host_resolved}" ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg title "Auth0 Tenant Domain Does Not Resolve for \`${AUTH0_TENANT}\`" \
        --arg details "DNS lookup for ${AUTH0_DOMAIN} failed. The tenant cannot be reached." \
        --argjson severity 1 \
        --arg next_steps "Verify the tenant name is correct and DNS for Auth0 managed domains is configured." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
fi

# --- 2. Well-known discovery endpoint ---
http_code=""
disc_body=""
http_code=$(curl -sS -o /tmp/auth0_disc_body.json -w "%{http_code}" --max-time 30 \
    "${AUTH0_BASE_URL}/.well-known/openid-configuration" || true)
disc_body=$(cat /tmp/auth0_disc_body.json 2>/dev/null || true)

if [ "${http_code}" = "000" ] || [ -z "${http_code}" ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg title "Auth0 Tenant Service Unreachable for \`${AUTH0_TENANT}\`" \
        --arg details "Connection to ${AUTH0_BASE_URL} failed (curl code ${http_code}). The Auth0 platform may be down or the tenant URL is wrong." \
        --argjson severity 1 \
        --arg next_steps "Check Auth0 platform status, verify the tenant name, and test connectivity from this host." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
elif [ "${http_code}" -ge 500 ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg title "Auth0 Tenant Service Returning 5xx for \`${AUTH0_TENANT}\`" \
        --arg details "Discovery endpoint returned HTTP ${http_code} (server error). The Auth0 platform is degraded for this tenant." \
        --argjson severity 1 \
        --arg next_steps "Check Auth0 platform status page and re-run after the incident clears." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
elif [ "${http_code}" != "200" ]; then
    # If discovery fails at non-5xx, the tenant may simply not support that path.
    echo "WARN: Discovery endpoint returned HTTP ${http_code} (non-fatal for reachability)."
fi

if [ -n "${disc_body}" ]; then
    authz_endpoint="$(echo "${disc_body}" | jq -r '.authorization_endpoint // empty' || true)"
    userinfo_endpoint="$(echo "${disc_body}" | jq -r '.userinfo_endpoint // empty' || true)"
    issuer="$(echo "${disc_body}" | jq -r '.issuer // "unknown"')"

    if [ -z "${authz_endpoint}" ] || [ -z "${userinfo_endpoint}" ]; then
        issues_json=$(echo "${issues_json}" | jq \
            --arg title "Auth0 Tenant Discovery Incomplete for \`${AUTH0_TENANT}\`" \
            --arg details "Discovery document missing authorization_endpoint and/or userinfo_endpoint (issuer: ${issuer})." \
            --argjson severity 2 \
            --arg next_steps "Confirm the tenant serves the standard OIDC discovery document; if issues persist contact Auth0 support." \
            '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
    else
        echo "Discovery OK. authorization_endpoint: ${authz_endpoint}; userinfo_endpoint: ${userinfo_endpoint}"
    fi
    echo "Discovery issuer: ${issuer}"
fi

# --- 3. Management API reachability ---
mapi_http_code=$(curl -sS -o /tmp/auth0_mapi_body.json -w "%{http_code}" --max-time 30 \
    -H "Authorization: Bearer ${AUTH0_MGMT_TOKEN}" \
    -H "Accept: application/json" \
    "$(auth0_mgmt_url "tenant" "settings")" || true)
if [ "${mapi_http_code}" = "000" ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg title "Auth0 Management API Unreachable for \`${AUTH0_TENANT}\`" \
        --arg details "Management API call to $(auth0_mgmt_url "tenant" "settings") failed to connect." \
        --argjson severity 2 \
        --arg next_steps "Verify the Management API is enabled and reachable for the tenant." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
elif [ "${mapi_http_code}" -ge 500 ]; then
    issues_json=$(echo "${issues_json}" | jq \
        --arg title "Auth0 Management API Returning 5xx for \`${AUTH0_TENANT}\`" \
        --arg details "Management API returned HTTP ${mapi_http_code} on tenant settings check." \
        --argjson severity 2 \
        --arg next_steps "Check Auth0 platform status; Management API may be degraded." \
        '. += [{"title": $title, "details": $details, "severity": $severity, "next_steps": $next_steps}]')
else
    echo "Management API reachable (HTTP ${mapi_http_code})."
fi

rm -f /tmp/auth0_disc_body.json /tmp/auth0_mapi_body.json || true

issues_json=$(echo "${issues_json}" | jq 'sort_by(.severity)')
echo "${issues_json}" > "${OUTPUT_FILE}"
echo "Availability check completed. Results saved to ${OUTPUT_FILE}"