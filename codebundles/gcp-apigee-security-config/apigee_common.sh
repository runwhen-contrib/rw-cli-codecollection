#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# apigee_common.sh -- shared helpers for gcp-apigee-security-config.
#
# Wraps token acquisition and REST GETs so the check scripts do not each
# reimplement Apigee auth, and so the response-SHAPE handling lives in one place.
# The `gcloud apigee` command group does not cover api products, developer apps,
# target servers or keystores; those must go through the Management REST API.
#
# RESPONSE SHAPES -- the trap this file exists to contain.
#
# The Apigee v1 discovery document
# (https://apigee.googleapis.com/$discovery/rest?version=v1) documents SOME list
# endpoints and omits others entirely. The omitted ones return a BARE JSON ARRAY
# OF STRINGS, not an object with a named list field:
#
#   DOCUMENTED (object with a named field, note the SINGULAR field names):
#     organizations/{org}/apiproducts        -> {"apiProduct":[ ... ]}
#     organizations/{org}/developers         -> {"developer":[ ... ]}
#     organizations/{org}/developers/{d}/apps-> {"app":[ ... ]}
#
#   UNDOCUMENTED (bare array of strings):
#     organizations/{org}/environments                      -> ["prod","test"]
#     organizations/{org}/environments/{env}/targetservers   -> ["ts-1"]
#     organizations/{org}/environments/{env}/keystores       -> ["ks-1"]
#
# Treating a bare array of strings as a list of objects is silent: `jq '.name'`
# on a string errors, the field comes back empty, and the loop body skips every
# element -- so the check reports clean without ever having looked at anything.
# Both of this bundle's environment-scoped checks did exactly that.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG      - Apigee organization name
#
# OPTIONAL ENV VARS:
#   APIGEE_API      - base URL of the Apigee management API (default v1)
#
# SOURCING:
#   . "$(dirname "${BASH_SOURCE[0]}")/apigee_common.sh"
# -----------------------------------------------------------------------------

APIGEE_API="${APIGEE_API:-https://apigee.googleapis.com/v1}"

# apigee_token
#   Prints a short-lived OAuth access token from the active gcloud identity
#   (activated in Suite Initialization, whose token probe already proved one can
#   be minted). Refreshed on every call so long loops do not hit token expiry
#   mid-collection.
apigee_token() {
    gcloud auth print-access-token 2>/dev/null \
        || gcloud auth application-default print-access-token 2>/dev/null \
        || echo ""
}

# apigee_get <api_path>
#   Authenticated GET against the Apigee management API; prints the response
#   body. On failure prints an empty string and returns 0, so callers can
#   degrade gracefully under `set -e`.
apigee_get() {
    curl -fsS -H "Authorization: Bearer $(apigee_token)" \
        "${APIGEE_API}/$1" 2>/dev/null || true
}

# apigee_str_list <api_path>
#   Reads one of the UNDOCUMENTED list endpoints, which return a bare array of
#   STRINGS. Prints one name per line, nothing at all when the response is not
#   an array. Deliberately does NOT accept an object: if one of these endpoints
#   ever starts returning objects, silence here is better than reading the wrong
#   field and reporting clean.
apigee_str_list() {
    apigee_get "$1" | jq -r 'if type == "array" then .[] | select(type == "string") else empty end' 2>/dev/null || true
}

# apigee_obj_list <api_path> <field>
#   Reads one of the DOCUMENTED list endpoints, which return an object with a
#   named array field. The field name varies per endpoint and is SINGULAR, which
#   is easy to get wrong:
#     /apiproducts             -> apiProduct
#     /developers              -> developer
#     /developers/{d}/apps     -> app
#   Prints the array as compact JSON, or [] when absent. Also accepts a bare
#   array, so a caller is not broken by an endpoint that returns one.
apigee_obj_list() {
    local body
    body="$(apigee_get "$1")"
    if [ -z "${body}" ]; then
        echo "[]"
        return 0
    fi
    echo "${body}" | jq -c --arg f "$2" \
        'if type == "array" then . elif (.[$f] // null) != null then .[$f] else [] end' \
        2>/dev/null || echo "[]"
}

# join_names <accumulator>
#   The accumulators below are newline-separated "  - <name>: <detail>" lines.
#   Prints just the names, comma separated, for an issue's `actual` field.
join_names() {
    printf '%s' "$1" | sed 's/^  - //; s/:.*//' | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}

# count_lines <accumulator>
count_lines() { printf '%s' "$1" | grep -c . ; }
