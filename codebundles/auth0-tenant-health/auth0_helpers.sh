#!/usr/bin/env bash
set -euo pipefail

# Temporarily disable errexit-alignment warnings from sourcing during trace
# ---------------------------------------------------------------------------
# SHARED HELPER: auth0_helpers.sh
#
# This file is meant to be sourced (not executed) by Auth0 analysis scripts.
# It:
#   1) Validates required env vars (AUTH0_TENANT, AUTH0_MGMT_CREDENTIALS)
#   2) Derives the tenant URL (https://<AUTH0_TENANT>.auth0.com)
#   3) Obtains a short-lived Management API bearer token via the
#      client_credentials grant against /oauth/token
#   4) Defines helper functions:
#        auth0_mgmt_url <path...>      -> full Management API v2 URL
#        auth0_get <path> [--params ..] -> curl GET with Authorization header
#
# The Management API bearer token is NOT stored/serialized; it is held in the
# AUTH0_MGMT_TOKEN environment variable for the lifetime of the script only.
# ---------------------------------------------------------------------------

: "${AUTH0_TENANT:?Must set AUTH0_TENANT}"
: "${AUTH0_MGMT_CREDENTIALS:?Must set AUTH0_MGMT_CREDENTIALS}"

AUTH0_DOMAIN="${AUTH0_TENANT}.auth0.com"
AUTH0_BASE_URL="https://${AUTH0_DOMAIN}"
AUTH0_API_URL="${AUTH0_BASE_URL}/api/v2"
AUTH0_TOKEN_URL="${AUTH0_BASE_URL}/oauth/token"
AUTH0_AUDIENCE="${AUTH0_API_URL}/"

# AUTH0_MGMT_CREDENTIALS is expected to be a JSON string (or an MAPI token):
#   {"client_id":"...","client_secret":"..."}  OR  <raw MAPI token>
# Try to parse it as JSON; fall back to treating the raw value as a token.
AUTH0_CLIENT_ID=""
AUTH0_CLIENT_SECRET=""
AUTH0_MGMT_TOKEN=""

if echo "${AUTH0_MGMT_CREDENTIALS}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    AUTH0_CLIENT_ID="$(echo "${AUTH0_MGMT_CREDENTIALS}" | jq -r '.client_id // .CLIENT_ID // empty')"
    AUTH0_CLIENT_SECRET="$(echo "${AUTH0_MGMT_CREDENTIALS}" | jq -r '.client_secret // .CLIENT_SECRET // empty')"
else
    # Azure/Machine-to-machine style: treat the raw credential as the token
    AUTH0_MGMT_TOKEN="${AUTH0_MGMT_CREDENTIALS}"
fi

if [ -z "${AUTH0_MGMT_TOKEN}" ] && [ -n "${AUTH0_CLIENT_ID}" ] && [ -n "${AUTH0_CLIENT_SECRET}" ]; then
    token_resp="$(curl -sS --max-time 30 -X POST "${AUTH0_TOKEN_URL}" \
        -H "Content-Type: application/json" \
        -d "{\"client_id\":\"${AUTH0_CLIENT_ID}\",\"client_secret\":\"${AUTH0_CLIENT_SECRET}\",\"audience\":\"${AUTH0_AUDIENCE}\",\"grant_type\":\"client_credentials\"}" \
        || echo '{"error":"request_failed"}')"
    AUTH0_MGMT_TOKEN="$(echo "${token_resp}" | jq -r '.access_token // empty')"
fi

if [ -z "${AUTH0_MGMT_TOKEN}" ]; then
    echo "ERROR: Failed to obtain Auth0 Management API token for tenant ${AUTH0_TENANT}." >&2
    exit 1
fi

# Convenience: full Management API URL builder (filters out empty args)
auth0_mgmt_url() {
    local base="${AUTH0_API_URL}"
    for arg in "$@"; do
        if [ -n "${arg}" ]; then
            base="${base}/${arg}"
        fi
    done
    printf '%s' "${base}"
}

# Convenience: GET against Management API, returns raw response body on stdout
auth0_get() {
    local url="$1"
    shift
    local params=()
    if [ $# -gt 0 ]; then
        params=(--get --data-urlencode "${1}")
        shift
        for p in "$@"; do
            params+=(--data-urlencode "${p}")
        done
    fi
    curl -sS --max-time 30 \
        -H "Authorization: Bearer ${AUTH0_MGMT_TOKEN}" \
        -H "Accept: application/json" \
        "${params[@]+"${params[@]}"}" \
        "${url}"
}

export AUTH0_TENANT AUTH0_DOMAIN AUTH0_BASE_URL AUTH0_API_URL AUTH0_TOKEN_URL
export AUTH0_MGMT_TOKEN AUTH0_CLIENT_ID AUTH0_CLIENT_SECRET