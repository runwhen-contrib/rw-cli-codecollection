#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# apigee_common.sh -- shared helper for gcp-apigee-* CodeBundles
#
# Wraps the bits every Apigee task needs in ONE place (shared with the sibling
# gcp-apigee-environment-health and gcp-apigee-product-governance bundles):
#
#   * Access token acquisition (from an activated gcloud service account)
#   * Apigee org resolution when APIGEE_ORG is not supplied
#   * REST pagination for list endpoints
#   * Cached discovery data (org-wide deployments + proxy list) so a run only
#     calls the org-wide /deployments endpoint ONCE, respecting rate limits.
#
# The Analytics stats endpoint is NOT exposed by the `gcloud apigee` command
# group, so every data fetch here goes over the Apigee Management REST API at
# https://apigee.googleapis.com. Credentials are provided as a GCP service
# account JSON key and activated via gcloud before the robot runs.
#
# Source this file from task scripts:  . "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"
# -----------------------------------------------------------------------------

set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

APIGEE_BASE="${APIGEE_BASE:-https://apigee.googleapis.com/v1}"

# Discovery cache files (shared by every task). A task reads these if they
# exist and falls back to fetching them directly otherwise (so sli.robot and
# standalone runs still work without the discovery task).
DEPLOYMENTS_FILE="${DEPLOYMENTS_FILE:-apigee_deployments.json}"
PROXIES_FILE="${PROXIES_FILE:-apigee_proxies.json}"

PYRATE='%.6f'

# --- Token --------------------------------------------------------------
# echo the bearer token used to authorize Apigee REST calls.
apigee_access_token() {
    if [ -n "${GCP_ACCESS_TOKEN:-}" ]; then
        printf '%s' "$GCP_ACCESS_TOKEN"
        return 0
    fi
    gcloud auth print-access-token 2>/dev/null || true
}

# --- REST -----------------------------------------------------------------
# apigee_curl <path_and_query>  -> raw response body on stdout
# path_and_query is relative to the API base (leading slash optional).
apigee_curl() {
    local token path
    token=$(apigee_access_token)
    path="$1"
    [ -z "$token" ] && { echo '{"error":{"code":401,"message":"no access token"}}'; return 0; }
    case "$path" in
        /*) curl -s -H "Authorization: Bearer $token" "${APIGEE_BASE}${path}" ;;
        *)  curl -s -H "Authorization: Bearer $token" "${APIGEE_BASE}/${path}" ;;
    esac
}

# apigee_paginate_json <path_no_query> <array_field>
# Follows nextPageToken across pages and returns ONE concatenated JSON array.
apigee_paginate_json() {
    local path field url token resp arr result next
    path="$1"; field="$2"; token=$(apigee_access_token)
    url="${APIGEE_BASE}/${path}"
    result='[]'
    while [ -n "$url" ]; do
        resp=$(curl -s -H "Authorization: Bearer $token" "$url" 2>/dev/null || echo '{}')
        arr=$(echo "$resp" | jq -c --arg f "$field" '.[$f] // []')
        result=$(jq -n --argjson a "$result" --argjson b "$arr" '$a + $b')
        next=$(echo "$resp" | jq -r '.nextPageToken // ""')
        if [ -n "$next" ] && [ "$next" != "null" ]; then
            if [[ "$url" == *\?* ]]; then
                url="${url}&pageToken=${next}"
            else
                url="${url}?pageToken=${next}"
            fi
        else
            url=""
        fi
    done
    echo "$result"
}

# --- Org resolution --------------------------------------------------------
# echo the Apigee org name for this project. Uses APIGEE_ORG if set, otherwise
# discovers it from /organizations by matching the GCP project id.
apigee_org() {
    if [ -n "${APIGEE_ORG:-}" ]; then
        printf '%s' "$APIGEE_ORG"
        return 0
    fi
    local resp
    resp=$(apigee_curl "/organizations" 2>/dev/null || echo '{}')
    echo "$resp" | jq -r --arg p "$GCP_PROJECT_ID" '
        (.organizations // [])[]
        | select(.projectId == $p or ((.projectIds // []) | index($p)))
        | .organization' | head -n 1
}

# --- Data sources ----------------------------------------------------------
# Org-wide deployments (ONE call). Returns a JSON array of Deployment objects.
apigee_list_deployments() {
    local org
    org="${1:-$(apigee_org)}"
    apigee_curl "/organizations/${org}/deployments" | jq -c '.deployments // []'
}

# API proxy list. Returns a JSON array of proxy names.
apigee_list_proxies() {
    local org
    org="${1:-$(apigee_org)}"
    apigee_curl "/organizations/${org}/apis?includeRevisions=false" \
        | jq -c '.proxies // [] | map(.name)'
}

# List revision numbers (array of strings) for a proxy.
apigee_list_revisions() {
    local org proxy
    org="$1"; proxy="$2"
    # revisions list returns a bare JSON array of revision strings
    apigee_curl "/organizations/${org}/apis/${proxy}/revisions" | jq -c 'map(tostring)'
}

# Highest (latest) revision number for a proxy, as an integer.
apigee_latest_revision() {
    local org proxy
    org="$1"; proxy="$2"
    apigee_curl "/organizations/${org}/apis/${proxy}/revisions" \
        | jq -r 'map(tonumber) | if length == 0 then 0 else max end'
}

# Environment names in the org (JSON array of strings).
apigee_list_environments() {
    local org
    org="$1"
    apigee_curl "/organizations/${org}/environments" | jq -c '.environments // []'
}

# --- Discovery cache -------------------------------------------------------
# Ensure the org-wide deployments + proxy list are cached on disk (only fetched
# once per run). Subsequent tasks read the cache.
apigee_ensure_discovery() {
    local org token
    org="${1:-$(apigee_org)}"
    token=$(apigee_access_token)
    if [ ! -s "$DEPLOYMENTS_FILE" ]; then
        curl -s -H "Authorization: Bearer $token" \
            "${APIGEE_BASE}/organizations/${org}/deployments" \
            | jq -c '.deployments // []' > "$DEPLOYMENTS_FILE" || rm -f "$DEPLOYMENTS_FILE"
    fi
    if [ ! -s "$PROXIES_FILE" ]; then
        curl -s -H "Authorization: Bearer $token" \
            "${APIGEE_BASE}/organizations/${org}/apis?includeRevisions=false" \
            | jq -c '.proxies // []' > "$PROXIES_FILE" || rm -f "$PROXIES_FILE"
    fi
}

# Load the cached org-wide deployments (or fetch if absent).
apigee_load_deployments() {
    if [ -s "$DEPLOYMENTS_FILE" ]; then
        cat "$DEPLOYMENTS_FILE"
    else
        apigee_list_deployments
    fi
}

# Load the cached proxy list (or fetch if absent). Returns proxy names array.
apigee_load_proxies() {
    if [ -s "$PROXIES_FILE" ]; then
        jq -c '[.[] | if type=="object" then .name else . end]' "$PROXIES_FILE"
    else
        apigee_list_proxies
    fi
}

# --- Analytics -------------------------------------------------------------
# Query the Analytics stats endpoint for a set of metrics grouped by a
# dimension. Path is /organizations/{org}/environments/{env}/stats/{dimension}.
# Returns the full Stats response JSON.
#
# Metric names are NOT hardcoded to the platform defaults lightly: the schema
# is org-specific, so scripts should double-check names against
# /organizations/{org}/environments/{env}/analytics/admin/schemav2. A wrong
# metric name returns an empty series and fails silently.
apigee_stats() {
    local org env dimension select tstart tend args
    org="$1"; env="$2"; dimension="$3"; select="$4"; tstart="$5"; tend="$6"
    args="select=$(jq -rn --arg v "$select" '$v|@uri')&timeRange=$(jq -rn --arg v "${tstart}~${tend}" '$v|@uri')"
    apigee_curl "/organizations/${org}/environments/${env}/stats/${dimension}?${args}&timeUnit=minute&sort=DESC&tsAscending=true"
}

# --- Operations ------------------------------------------------------------
# Long-running operations (deployment/environment/instance changes). Returns a
# JSON array of Operation objects.
apigee_list_operations() {
    local org filter
    org="$1"; filter="${2:-}"
    if [ -n "$filter" ]; then
        apigee_paginate_json "organizations/${org}/operations?filter=$(jq -rn --arg v "$filter" '$v|@uri')" "operations"
    else
        apigee_paginate_json "organizations/${org}/operations" "operations"
    fi
}

# --- Filtering helpers -----------------------------------------------------
# Expand a comma-separated PROXIES/ENVIRONMENTS user variable into a jq @csv
# safe list. "All" / empty means no filtering. Returns a comma-joined string.
apigee_expand_csv() {
    local in
    in="${1:-}"
    [ -z "$in" ] && { echo "All"; return 0; }
    if [ "$in" = "All" ]; then
        echo "All"; return 0
    fi
    echo "$in" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | paste -sd, -
}
