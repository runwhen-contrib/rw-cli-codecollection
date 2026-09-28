#!/bin/bash
# ---------------------------------------------------------------------------
# Shared oVirt SSO authentication + REST API helper.
#
# Source this from each check script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/ovirt_auth.sh"
#   hosts=$(ovirt_get "/hosts")
#
# Requires env: OVIRT_ENGINE_URL, OVIRT_USERNAME, OVIRT_PASSWORD
# Optional env: OVIRT_CA_CERT (PEM CA bundle; if unset, the system trust
#               store is used).
#
# On any failure to authenticate, prints an {"error": "..."} JSON object to
# stdout and exits non-zero so the calling task surfaces an engine issue.
# ---------------------------------------------------------------------------

if [ -z "${OVIRT_ENGINE_URL}" ] || [ -z "${OVIRT_USERNAME}" ] || [ -z "${OVIRT_PASSWORD}" ]; then
    echo '{"error": "OVIRT_ENGINE_URL, OVIRT_USERNAME and OVIRT_PASSWORD must be set."}'
    exit 1
fi

# Strip any trailing slash so path concatenation is predictable.
OVIRT_ENGINE_URL="${OVIRT_ENGINE_URL%/}"

# TLS handling: use a caller-supplied CA bundle when present, otherwise rely on
# the system trust store.
OVIRT_CURL_TLS_OPTS=()
if [ -n "${OVIRT_CA_CERT}" ]; then
    OVIRT_CA_FILE="$(mktemp)"
    printf '%s\n' "${OVIRT_CA_CERT}" > "${OVIRT_CA_FILE}"
    OVIRT_CURL_TLS_OPTS=(--cacert "${OVIRT_CA_FILE}")
    trap 'rm -f "${OVIRT_CA_FILE}"' EXIT
fi

# Obtain an SSO bearer token (grant_type=password, scope=ovirt-app-api).
_ovirt_token_response=$(curl -s "${OVIRT_CURL_TLS_OPTS[@]}" \
    --request POST \
    --header "Accept: application/json" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "scope=ovirt-app-api" \
    --data-urlencode "username=${OVIRT_USERNAME}" \
    --data-urlencode "password=${OVIRT_PASSWORD}" \
    "${OVIRT_ENGINE_URL}/ovirt-engine/sso/oauth/token")

OVIRT_TOKEN=$(echo "${_ovirt_token_response}" | jq -r '.access_token // empty' 2>/dev/null)

if [ -z "${OVIRT_TOKEN}" ]; then
    err=$(echo "${_ovirt_token_response}" | jq -r '.error_description // .error // "unknown error (check OVIRT_ENGINE_URL, credentials and TLS)"' 2>/dev/null)
    echo "{\"error\": \"Failed to obtain oVirt SSO token: ${err}\"}"
    exit 1
fi

# ovirt_get <api-path>
#   e.g. ovirt_get "/hosts" -> GET {engine}/ovirt-engine/api/hosts
ovirt_get() {
    local path="$1"
    curl -s "${OVIRT_CURL_TLS_OPTS[@]}" \
        --header "Authorization: Bearer ${OVIRT_TOKEN}" \
        --header "Accept: application/json" \
        --header "Version: 4" \
        "${OVIRT_ENGINE_URL}/ovirt-engine/api${path}"
}

# ovirt_duration_to_seconds <duration>
#   Accepts forms like 30s, 10m, 2h, 7d, 1w. Defaults the unit to hours.
ovirt_duration_to_seconds() {
    local s num unit
    s=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    num=$(echo "$s" | grep -o '^[0-9]\+')
    unit=$(echo "$s" | sed 's/^[0-9]\+//')
    [ -z "$num" ] && { echo 0; return; }
    case "$unit" in
        s|sec|secs|second|seconds)   echo "$num" ;;
        m|min|mins|minute|minutes)   echo $((num * 60)) ;;
        h|hr|hrs|hour|hours)         echo $((num * 3600)) ;;
        d|day|days)                  echo $((num * 86400)) ;;
        w|week|weeks)                echo $((num * 604800)) ;;
        *)                           echo $((num * 3600)) ;;
    esac
}
