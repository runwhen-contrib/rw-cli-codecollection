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
#   * Cached discovery data (org-wide deployments enriched with runtime status,
#     plus the proxy list with revisions) so a run makes the expensive calls
#     ONCE, respecting rate limits.
#
# The Analytics stats endpoint is NOT exposed by the `gcloud apigee` command
# group, so every data fetch here goes over the Apigee Management REST API at
# https://apigee.googleapis.com. Credentials are provided as a GCP service
# account JSON key and activated via gcloud before the robot runs.
#
# Response shapes below are taken from the Apigee Management API discovery
# document, NOT from what callers would like them to be:
#   curl -sf "https://apigee.googleapis.com/\$discovery/rest?version=v1"
# The traps that document reveals are called out at each helper.
#
# Source this file from task scripts:  . "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"
# -----------------------------------------------------------------------------

set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

APIGEE_BASE="${APIGEE_BASE:-https://apigee.googleapis.com/v1}"

# Discovery cache files (shared by every task). A task reads these if they
# exist and falls back to fetching them directly otherwise, so a task can still
# run standalone without the discovery task having populated the cache.
DEPLOYMENTS_FILE="${DEPLOYMENTS_FILE:-apigee_deployments.json}"
PROXIES_FILE="${PROXIES_FILE:-apigee_proxies.json}"

# Upper bound on per-deployment runtime-status calls made during discovery.
# Exceeding it is reported, never silently truncated.
APIGEE_MAX_STATUS_CALLS="${APIGEE_MAX_STATUS_CALLS:-250}"

# --- Token --------------------------------------------------------------
# echo the bearer token used to authorize Apigee REST calls.
apigee_access_token() {
    if [ -n "${GCP_ACCESS_TOKEN:-}" ]; then
        printf '%s' "$GCP_ACCESS_TOKEN"
        return 0
    fi
    gcloud auth print-access-token 2>/dev/null || true
}

# --- API error tracking ----------------------------------------------------
# A non-2xx response body has no `deployments` / `proxies` / `environments` key,
# so `jq '.deployments // []'` turns 403 PERMISSION_DENIED into [] and every
# downstream check reads "nothing found" as "nothing wrong". Guarding only the
# empty-token path is not enough: with APIGEE_ORG supplied, org resolution is
# skipped and a wholly inaccessible org scores perfect health.
#
# Every call therefore records its HTTP status, and callers ask whether the data
# they are about to judge was actually retrieved.
APIGEE_API_ERRORS_FILE="${APIGEE_API_ERRORS_FILE:-apigee_api_errors.json}"

apigee_reset_api_errors() {
    echo '[]' > "$APIGEE_API_ERRORS_FILE"
}

apigee_record_api_error() {
    local code path body msg
    code="$1"; path="$2"; body="$3"
    [ -s "$APIGEE_API_ERRORS_FILE" ] || echo '[]' > "$APIGEE_API_ERRORS_FILE"
    msg=$(printf '%s' "$body" | jq -r 'if type=="object" then (.error.message // .message // "") else "" end' 2>/dev/null || echo "")
    [ -z "$msg" ] && msg="HTTP $code with no error body"
    jq --arg c "$code" --arg p "$path" --arg m "$msg" \
       '. += [{status: (($c|tonumber?) // 0), path: $p, message: $m}]' \
       "$APIGEE_API_ERRORS_FILE" > "${APIGEE_API_ERRORS_FILE}.tmp" 2>/dev/null \
       && mv "${APIGEE_API_ERRORS_FILE}.tmp" "$APIGEE_API_ERRORS_FILE"
}

apigee_api_error_count() {
    if [ -s "$APIGEE_API_ERRORS_FILE" ]; then
        jq 'length' "$APIGEE_API_ERRORS_FILE" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# One-line summary of the distinct failures seen, for issue text.
apigee_api_error_summary() {
    if [ -s "$APIGEE_API_ERRORS_FILE" ]; then
        jq -r '[group_by(.status)[] | "HTTP \(.[0].status) x\(length) (\(.[0].message))"] | join("; ")' \
            "$APIGEE_API_ERRORS_FILE" 2>/dev/null || echo "unknown API errors"
    else
        echo "none"
    fi
}

# --- REST -----------------------------------------------------------------
# apigee_curl <path_and_query>  -> raw response body on stdout
# path_and_query is relative to the API base (leading slash optional).
# A non-2xx status is recorded before the body is returned, so callers that
# degrade it to [] can still tell the difference between "empty" and "failed".
apigee_curl() {
    local token path url resp body code
    token=$(apigee_access_token)
    path="$1"
    [ -z "$token" ] && { echo '{"error":{"code":401,"message":"no access token"}}'; return 0; }
    case "$path" in
        /*) url="${APIGEE_BASE}${path}" ;;
        *)  url="${APIGEE_BASE}/${path}" ;;
    esac
    resp=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $token" "$url" 2>/dev/null || printf '\n000')
    code="${resp##*$'\n'}"
    body="${resp%$'\n'*}"
    case "$code" in
        2??) : ;;
        *)   apigee_record_api_error "$code" "$path" "$body" ;;
    esac
    printf '%s' "$body"
}

# apigee_paginate_json <path_no_query> <array_field>
# Follows nextPageToken across pages and returns ONE concatenated JSON array.
apigee_paginate_json() {
    local base field url resp arr result next
    base="$1"; field="$2"
    result='[]'; next=""
    while :; do
        # Rebuild from the base each time: appending to the previous URL
        # accumulates stale pageToken parameters.
        url="$base"
        if [ -n "$next" ]; then
            case "$base" in
                *\?*) url="${base}&pageToken=${next}" ;;
                *)    url="${base}?pageToken=${next}" ;;
            esac
        fi
        resp=$(apigee_curl "$url")
        arr=$(printf '%s' "$resp" | jq -c --arg f "$field" 'if type=="object" then (.[$f] // []) else [] end' 2>/dev/null || echo '[]')
        result=$(jq -n --argjson a "$result" --argjson b "$arr" '$a + $b')
        next=$(printf '%s' "$resp" | jq -r 'if type=="object" then (.nextPageToken // "") else "" end' 2>/dev/null || echo "")
        if [ -z "$next" ] || [ "$next" = "null" ]; then
            break
        fi
    done
    echo "$result"
}

# --- Probe -----------------------------------------------------------------
# apigee_probe <path>
# Like apigee_curl, but hands the caller the HTTP status and the body SEPARATELY
# and does NOT record an API error. apigee_curl decides that any non-2xx is a
# failure; the caller here needs to decide, because for the /organizations
# lookup a 403 can mean either "the API is switched off, so no org can exist"
# (a definite answer) or "you lack permission" (no answer at all).
#
# Sets APIGEE_PROBE_STATUS and APIGEE_PROBE_BODY. Exported rather than plain
# globals so shellcheck can see they leave this file: callers source it and read
# both, which SC2034 cannot infer.
export APIGEE_PROBE_STATUS=""
export APIGEE_PROBE_BODY=""
apigee_probe() {
    local token path url resp
    token=$(apigee_access_token)
    path="$1"
    if [ -z "$token" ]; then
        APIGEE_PROBE_STATUS="000"
        APIGEE_PROBE_BODY='{"error":{"code":401,"message":"no access token"}}'
        return 0
    fi
    case "$path" in
        /*) url="${APIGEE_BASE}${path}" ;;
        *)  url="${APIGEE_BASE}/${path}" ;;
    esac
    resp=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $token" "$url" 2>/dev/null || printf '\n000')
    APIGEE_PROBE_STATUS="${resp##*$'\n'}"
    APIGEE_PROBE_BODY="${resp%$'\n'*}"
}

# INTERIM (remove when the indexer gates on gcp_apigee_organizations):
# apigee_api_disabled <status> <body>
# True only when the response DEFINITIVELY says the Apigee API was never enabled
# on this project. If it was never enabled, no organization can exist -- that is
# a positive determination of absence, not a failed lookup.
#
# The match list is deliberately narrow. Widening it to bare PERMISSION_DENIED
# would classify "you lack permission" as "there is no Apigee here", which
# resurrects exactly the healthy-while-blind scoring this bundle was fixed to
# remove. The offline tier has an assertion specifically to catch that.
apigee_api_disabled() {
    local status="$1" body="$2"
    case "$status" in
        403|404) ;;
        *) return 1 ;;
    esac
    printf '%s' "$body" \
        | grep -qE 'SERVICE_DISABLED|has not been used in project|accessNotConfigured|API has not been used'
}

# --- Topology --------------------------------------------------------------
# INTERIM: carries the applicability verdict alongside the resolved org, so the
# check scripts read one answer instead of each re-deriving it.
APIGEE_TOPOLOGY_FILE="${APIGEE_TOPOLOGY_FILE:-apigee_topology.json}"

# apigee_write_topology <applicable:true|false> <organization> <reason>
# Empty collections are written as real empty ARRAYS, never as {} or omitted:
# downstream `jq` must read `[]` rather than null, or `(.list)[]` aborts under
# `set -e` and the caller cannot tell empty from malformed.
apigee_write_topology() {
    jq -n --argjson applicable "$1" --arg org "$2" --arg reason "$3" \
        '{applicable: $applicable, organization: $org, reason: $reason,
          environments: [], proxies: [], deployments: []}' \
        > "$APIGEE_TOPOLOGY_FILE"
}

# Is this project in scope at all? Absent topology means discovery has not run,
# which is NOT a determination of absence -- default to applicable so the normal
# failure path applies.
apigee_applicable() {
    if [ ! -s "$APIGEE_TOPOLOGY_FILE" ]; then
        echo "true"; return 0
    fi
    # `has()` rather than `.applicable // "true"`: `//` falls through on `false`
    # as well as null, so a correctly-set false would read as the default.
    jq -r 'if has("applicable") then (.applicable | tostring) else "true" end' \
        "$APIGEE_TOPOLOGY_FILE" 2>/dev/null || echo "true"
}

# --- Org resolution --------------------------------------------------------
# echo the Apigee org name for this project. Uses APIGEE_ORG if set, otherwise
# the topology discovery wrote, otherwise looks it up.
apigee_org() {
    if [ -n "${APIGEE_ORG:-}" ]; then
        # The API resource name is "organizations/{org}" but every path here
        # already supplies the "/organizations/" segment. Accept either form:
        # the sibling gcp-apigee-* bundles disagree on which to configure, and
        # the prefixed value would otherwise build
        # /organizations/organizations/{org} and 404 on every call.
        printf '%s' "${APIGEE_ORG#organizations/}"
        return 0
    fi
    # Prefer the topology discovery already resolved: re-probing per check
    # multiplies calls against a rate-limited management API, and on a
    # not-applicable project every check would repeat the same lookup.
    if [ -s "$APIGEE_TOPOLOGY_FILE" ]; then
        local t_org
        if [ "$(apigee_applicable)" = "false" ]; then
            printf ''
            return 0
        fi
        t_org=$(jq -r '.organization // ""' "$APIGEE_TOPOLOGY_FILE" 2>/dev/null || echo "")
        if [ -n "$t_org" ]; then
            printf '%s' "$t_org"
            return 0
        fi
    fi
    local resp
    resp=$(apigee_curl "/organizations" 2>/dev/null || echo '{}')
    echo "$resp" | jq -r --arg p "$GCP_PROJECT_ID" '
        (.organizations // [])[]
        | select(.projectId == $p or ((.projectIds // []) | index($p)))
        | .organization' 2>/dev/null | head -n 1
}

# --- Data sources ----------------------------------------------------------
# Org-wide deployments (ONE call). Returns a JSON array of Deployment objects.
#
# TRAP: this response carries environment/apiProxy/revision but NOT `state` or
# `errors[]`. The discovery document marks both "displayed only when viewing
# deployment status", and organizations.deployments.list has no parameter to
# request them. Use apigee_deployment_status() for runtime state.
apigee_list_deployments() {
    local org
    org="${1:-$(apigee_org)}"
    apigee_curl "/organizations/${org}/deployments" | jq -c '.deployments // []'
}

# API proxy list WITH revisions, in one call. Returns a JSON array of ApiProxy
# objects ({name, revision[], latestRevisionId}). includeRevisions=true avoids
# a per-proxy revision call for every proxy in the org.
apigee_list_proxy_objects() {
    local org
    org="${1:-$(apigee_org)}"
    apigee_curl "/organizations/${org}/apis?includeRevisions=true" \
        | jq -c '.proxies // []'
}

# API proxy list. Returns a JSON array of proxy names.
apigee_list_proxies() {
    apigee_list_proxy_objects "${1:-}" | jq -c 'map(.name)'
}

# Environment names in the org (JSON array of strings).
#
# TRAP: /organizations/{org}/environments has no `list` method in the discovery
# document (only POST to create, and GET on a single environment). It is an
# Edge-compatibility path that returns a BARE JSON array of names, not
# {"environments":[...]}. Indexing that with a string is a jq error, which
# silently empties the caller's for-loop. Accept both shapes, and fall back to
# the documented Organization resource, which carries `environments`.
apigee_list_environments() {
    local org resp out
    org="$1"
    resp=$(apigee_curl "/organizations/${org}/environments")
    out=$(printf '%s' "$resp" | jq -c '
        if type == "array" then .
        elif type == "object" then (.environments // [])
        else [] end' 2>/dev/null || echo '[]')
    if [ "$out" = "[]" ]; then
        out=$(apigee_curl "/organizations/${org}" \
              | jq -c 'if type=="object" then (.environments // []) else [] end' 2>/dev/null || echo '[]')
    fi
    printf '%s' "$out"
}

# --- Deployment runtime status ---------------------------------------------
# apigee_deployment_status <org> <env> <proxy> <revision>
# Returns the Deployment object from the deployment STATUS view, which is the
# only view populating `state`, `errors[]`, `routeConflicts[]` and `instances[]`.
apigee_deployment_status() {
    local org env proxy rev
    org="$1"; env="$2"; proxy="$3"; rev="$4"
    apigee_curl "/organizations/${org}/environments/${env}/apis/${proxy}/revisions/${rev}/deployments"
}

# apigee_enrich_deployments <org> <deployments_json>
# Merges runtime state/errors[] onto each deployment via the status view.
# Deployments whose status could not be read get state "UNKNOWN" -- never a
# value a caller could mistake for healthy.
apigee_enrich_deployments() {
    local org deployments count i dep env proxy rev status state errors enriched
    org="$1"; deployments="$2"
    count=$(printf '%s' "$deployments" | jq 'length')
    enriched='[]'
    i=0
    while [ "$i" -lt "$count" ]; do
        dep=$(printf '%s' "$deployments" | jq -c ".[$i]")
        if [ "$i" -ge "$APIGEE_MAX_STATUS_CALLS" ]; then
            enriched=$(jq -n --argjson a "$enriched" --argjson d "$dep" \
                '$a + [$d + {state:"UNKNOWN", errors:[], statusUnavailable:true, statusSkippedReason:"status call budget exhausted"}]')
            i=$((i + 1))
            continue
        fi
        env=$(printf '%s' "$dep" | jq -r '.environment // ""')
        proxy=$(printf '%s' "$dep" | jq -r '.apiProxy // ""')
        rev=$(printf '%s' "$dep" | jq -r '.revision // ""')
        status=$(apigee_deployment_status "$org" "$env" "$proxy" "$rev" 2>/dev/null || echo '{}')
        state=$(printf '%s' "$status" | jq -r 'if type=="object" and has("state") then .state else "" end' 2>/dev/null || echo "")
        errors=$(printf '%s' "$status" | jq -c 'if type=="object" then (.errors // []) else [] end' 2>/dev/null || echo '[]')
        if [ -z "$state" ] || [ "$state" = "null" ]; then
            enriched=$(jq -n --argjson a "$enriched" --argjson d "$dep" \
                '$a + [$d + {state:"UNKNOWN", errors:[], statusUnavailable:true, statusSkippedReason:"deployment status view returned no state"}]')
        else
            enriched=$(jq -n --argjson a "$enriched" --argjson d "$dep" --arg s "$state" --argjson e "$errors" \
                '$a + [$d + {state:$s, errors:$e, statusUnavailable:false}]')
        fi
        i=$((i + 1))
    done
    printf '%s' "$enriched"
}

# --- Discovery cache -------------------------------------------------------
# Ensure the enriched deployments + proxy list are cached on disk (only fetched
# once per run). Subsequent tasks read the cache.
apigee_ensure_discovery() {
    local org deployments
    org="${1:-$(apigee_org)}"
    if [ ! -s "$DEPLOYMENTS_FILE" ]; then
        deployments=$(apigee_list_deployments "$org")
        apigee_enrich_deployments "$org" "$deployments" > "$DEPLOYMENTS_FILE" \
            || rm -f "$DEPLOYMENTS_FILE"
    fi
    if [ ! -s "$PROXIES_FILE" ]; then
        apigee_list_proxy_objects "$org" > "$PROXIES_FILE" || rm -f "$PROXIES_FILE"
    fi
}

# Load the cached org-wide deployments (or fetch + enrich if absent).
apigee_load_deployments() {
    if [ -s "$DEPLOYMENTS_FILE" ]; then
        cat "$DEPLOYMENTS_FILE"
    else
        local org deployments
        org="$(apigee_org)"
        deployments=$(apigee_list_deployments "$org")
        apigee_enrich_deployments "$org" "$deployments"
    fi
}

# Load the cached proxy objects (or fetch if absent).
apigee_load_proxy_objects() {
    if [ -s "$PROXIES_FILE" ]; then
        jq -c '[.[] | if type=="object" then . else {name: .} end]' "$PROXIES_FILE"
    else
        apigee_list_proxy_objects
    fi
}

# Load the cached proxy list (or fetch if absent). Returns proxy names array.
apigee_load_proxies() {
    apigee_load_proxy_objects | jq -c 'map(.name)'
}

# Revision numbers (JSON array of strings) for a proxy, from the cached
# /apis?includeRevisions=true payload -- no extra API call.
apigee_cached_revisions() {
    local proxy="$1"
    apigee_load_proxy_objects \
        | jq -c --arg p "$proxy" '[.[] | select(.name == $p) | (.revision // [])[] | tostring]'
}

# Highest (latest) revision for a proxy as a string, from the cached payload.
# Prefers the API's own latestRevisionId; falls back to max(revision[]).
apigee_cached_latest_revision() {
    local proxy="$1"
    apigee_load_proxy_objects | jq -r --arg p "$proxy" '
        ([.[] | select(.name == $p)] | .[0]) // {}
        | (.latestRevisionId
           // ((.revision // []) | map(tonumber? // 0) | if length == 0 then 0 else max end))
        | tostring'
}

# --- Analytics -------------------------------------------------------------
# Query the Analytics stats endpoint for a set of metrics grouped by a
# dimension. Path is /organizations/{org}/environments/{env}/stats/{dimension}.
# Returns the full Stats response JSON.
#
# No timeUnit is requested: with a time unit the API returns a bucketed series
# and callers must aggregate it themselves, which invites reading bucket 0 and
# calling it the window. Without one it returns a single aggregate value per
# metric over the whole timeRange, which is what every caller here wants.
#
# Metric names are NOT hardcoded to the platform defaults lightly: the schema
# is org-specific, so scripts should double-check names against
# /organizations/{org}/environments/{env}/analytics/admin/schemav2. A wrong
# metric name returns an empty series and fails silently.
apigee_stats() {
    local org env dimension select tstart tend args
    org="$1"; env="$2"; dimension="$3"; select="$4"; tstart="$5"; tend="$6"
    args="select=$(jq -rn --arg v "$select" '$v|@uri')&timeRange=$(jq -rn --arg v "${tstart}~${tend}" '$v|@uri')"
    apigee_curl "/organizations/${org}/environments/${env}/stats/${dimension}?${args}"
}

# Dimensions array from a Stats response, tolerating a degraded document.
apigee_stats_dimensions() {
    jq -c 'if type=="object" then ((.environments // [])[0].dimensions // []) else [] end' 2>/dev/null \
        || echo '[]'
}

# apigee_metric <dimension_json> <metric_name_substring> [sum|max]
# Metric.values has two documented shapes -- ["39.0"] and
# [{"value":"39.0","timestamp":...}] -- and which one you get depends on
# whether timeUnit was requested. Handle both, and aggregate every element
# rather than reading only the first. Non-numeric entries are dropped, so a
# malformed value yields 0 instead of a string that poisons later arithmetic.
apigee_metric() {
    local dim name op
    dim="$1"; name="$2"; op="${3:-sum}"
    printf '%s' "$dim" | jq -r --arg n "$name" --arg op "$op" '
        [ .metrics[]? | select(.name | contains($n)) | .values[]?
          | (if type == "object" then .value else . end)
          | tonumber? // empty ]
        | if length == 0 then 0
          elif $op == "max" then max
          else add end
    ' 2>/dev/null || echo 0
}

# Dimension name for a DimensionMetric. `name` is comma-joined and marked
# deprecated in the discovery document ("if name already has comma before join,
# we may get wrong splits"); individualNames is the supported replacement.
# apigee_dimension_part <dimension_json> <zero-based index>
apigee_dimension_part() {
    local dim idx
    dim="$1"; idx="$2"
    printf '%s' "$dim" | jq -r --argjson i "$idx" '
        if (.individualNames | type) == "array" and ((.individualNames | length) > $i)
        then .individualNames[$i]
        else ((.name // "") | split(",") | (.[$i] // ""))
        end' 2>/dev/null || echo ""
}

# --- Operations ------------------------------------------------------------
# Long-running operations (deployment/environment/instance changes). Returns a
# JSON array of Operation objects.
#
# NOTE: neither Operation nor its OperationMetadata carries a timestamp
# (metadata fields are targetResourceName, state, warnings, operationType,
# progress). Callers cannot time-bound these results.
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

# --- Issue helpers ---------------------------------------------------------
# Start an issues file as an empty array so a stale file from an earlier run in
# the same working directory can never be mistaken for this run's findings.
apigee_init_issues() {
    echo '[]' > "$1"
}

# apigee_append_api_error_issue <issues_json> <context>
# Echoes the issues array with an API-failure issue appended when any call made
# by this script returned non-2xx. A task that could not query must not report
# "no problems found": absence of findings is only meaningful if the data was
# actually retrieved.
apigee_append_api_error_issue() {
    local issues context count summary
    issues="$1"; context="$2"
    count=$(apigee_api_error_count)
    if [ "$count" -eq 0 ]; then
        printf '%s' "$issues"
        return 0
    fi
    summary=$(apigee_api_error_summary)
    printf '%s' "$issues" | jq \
        --arg title "Apigee API calls failed during $context" \
        --arg details "$count Apigee API call(s) returned a non-2xx status: $summary. Results for $context are incomplete; the absence of findings here does not mean the absence of problems." \
        --arg severity "3" \
        --arg expected "Every Apigee API call should return 2xx" \
        --arg actual "$count call(s) failed: $summary" \
        --arg next_steps "Confirm the Apigee API is enabled for this project and the service account holds roles/apigee.readOnlyAdmin plus roles/apigee.analyticsViewer (the Analytics stats endpoint needs the latter). 403 usually means a disabled API or missing IAM; 404 a wrong APIGEE_ORG or environment; 429 quota exhaustion." \
        '. += [{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps}]'
}
