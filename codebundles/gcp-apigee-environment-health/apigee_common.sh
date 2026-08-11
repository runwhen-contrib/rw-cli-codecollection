#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# apigee_common.sh -- shared helpers for gcp-apigee-environment-health, written
# to be reusable by any future Apigee bundle in this collection (none exist
# yet).
#
# Wraps token acquisition, REST GET calls and list paging so such bundles would
# not duplicate Apigee REST/auth logic. The `gcloud apigee` command group
# does NOT cover envgroups, attachments, instances, target servers, keystores
# or aliases -- those must be reached through the Apigee Management REST API.
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project that owns the Apigee organization
#
# OPTIONAL ENV VARS:
#   APIGEE_API      - base URL of the Apigee management API (default v1)
#
# SOURCING:
#   Source this file from the task scripts: . ./apigee_common.sh
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

APIGEE_API="${APIGEE_API:-https://apigee.googleapis.com/v1}"

# get_apigee_token
#   Prints a short-lived OAuth access token derived from the active gcloud
#   service account (activated in Suite Setup). Refreshes on every call so
#   long discovery loops do not hit token expiry mid-collection.
get_apigee_token() {
    gcloud auth print-access-token 2>/dev/null
}

# apigee_get <api_path>
#   Performs an authenticated GET against the Apigee management API and prints
#   the response body to stdout. On failure prints an empty string and returns
#   0 so callers can degrade gracefully under `set -e`.
#   <api_path> is everything AFTER the version prefix, e.g.
#     "organizations/my-org/environments"
apigee_get() {
    local path="$1"
    local token
    token="$(get_apigee_token)"
    curl -fsS \
        -H "Authorization: Bearer ${token}" \
        "${APIGEE_API}/${path}" 2>/dev/null || true
}

# apigee_probe <api_path> <outfile>
#   GETs <api_path>, writing the response body to <outfile> whatever the status,
#   and prints the HTTP status code ("000" if the request could not be made).
#
#   apigee_get collapses every failure into an empty string, which makes "this
#   project has no Apigee organization" indistinguishable from "the request
#   failed". That distinction decides whether a result is reported as
#   not-applicable or as a failure, so it needs the status code.
apigee_probe() {
    local path="$1"
    local outfile="$2"
    local token
    token="$(get_apigee_token)"
    curl -sS -o "${outfile}" -w '%{http_code}' \
        -H "Authorization: Bearer ${token}" \
        "${APIGEE_API}/${path}" 2>/dev/null || echo "000"
}

# apigee_get_raw <api_path> <outfile> <errfile>
#   Like apigee_get but writes the body to <outfile> and returns non-zero when
#   the request fails so the caller can surface the error message.
apigee_get_raw() {
    local path="$1"
    local outfile="$2"
    local errfile="$3"
    local token
    token="$(get_apigee_token)"
    curl -fsS \
        -H "Authorization: Bearer ${token}" \
        "${APIGEE_API}/${path}" >"${outfile}" 2>"${errfile}"
}

# apigee_resolve_org [topology_file]
#   Resolves the Apigee org name for the current run. Prefers an explicitly set
#   APIGEE_ORG; when that is empty (the documented default), falls back to the
#   org that discover_topology.sh resolved and recorded in the topology dump.
#   Prints the resolved name, or an empty string when neither source has one.
#   A leading "organizations/" is stripped, because every caller interpolates
#   the result into a REST path that already carries that prefix.
apigee_resolve_org() {
    local topology="${1:-apigee_topology.json}"
    local org=""
    if [ -n "${APIGEE_ORG:-}" ]; then
        org="${APIGEE_ORG}"
    elif [ -f "${topology}" ]; then
        org="$(jq -r '.org.name // ""' "${topology}" 2>/dev/null || echo "")"
    fi
    echo "${org#organizations/}"
}

# apigee_list_field <api_path> <field>
#   Reads a list endpoint that returns an object with a named array field. The
#   field name varies per endpoint, so callers must pass the right one:
#     /instances/{i}/attachments  -> { "attachments": [...] }
#     /envgroups/{eg}/attachments -> { "environmentGroupAttachments": [...] }
#     /instances                  -> { "instances": [...] }
#     /envgroups                  -> { "environmentGroups": [...] }
#   Prints the raw array (or [] if missing). Handles the case where the endpoint
#   already returns a bare array.
apigee_list_field() {
    local path="$1"
    local field="$2"
    local body
    body="$(apigee_get "${path}")"
    if [ -z "${body}" ]; then
        echo "[]"
        return 0
    fi
    case "${body}" in
      \[*) echo "${body}" ;;
      *)   echo "${body}" | jq -c ".${field} // []" ;;
    esac
}
