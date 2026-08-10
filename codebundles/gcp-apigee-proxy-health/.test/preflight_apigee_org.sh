#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# preflight_apigee_org.sh
# Verifies the shared Apigee X test organization this bundle's fixtures depend
# on actually exists and is reachable, BEFORE the bootstrap starts creating
# proxies against it.
#
# The org is not created here and cannot be: an Apigee X organization is
# one-per-project, takes roughly 45 minutes to provision, and is owned by the
# gcp-apigee-environment-health sibling bundle's bootstrap. Without this check
# the failure surfaces as a wall of confusing 404s from the fixture uploads,
# and the next person concludes the harness is broken rather than incomplete.
#
# REQUIRED ENV:
#   GCP_PROJECT_ID - GCP project owning the Apigee org
#   APIGEE_ORG     - optional; resolved from GCP_PROJECT_ID when empty
#
# Exits non-zero, with what to do about it, if the prerequisite is missing.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
BASE="https://apigee.googleapis.com/v1"

fail() {
    echo "" >&2
    echo "PREFLIGHT FAILED: $1" >&2
    shift
    for line in "$@"; do echo "  $line" >&2; done
    echo "" >&2
    exit 1
}

TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
[ -z "$TOKEN" ] && fail "no gcloud access token." \
    "Run: gcloud auth activate-service-account --key-file=gcp.json.secret"

# --- org exists and is reachable --------------------------------------------
if [ -n "${APIGEE_ORG:-}" ]; then
    ORG="$APIGEE_ORG"
else
    resp=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/organizations")
    code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
    [ "${code:0:1}" != "2" ] && fail "listing Apigee organizations returned HTTP $code." \
        "$(printf '%s' "$body" | jq -r '.error.message // "no error message"' 2>/dev/null)" \
        "Enable the Apigee API for '$GCP_PROJECT_ID' and grant roles/apigee.readOnlyAdmin."
    ORG=$(printf '%s' "$body" | jq -r --arg p "$GCP_PROJECT_ID" \
        '(.organizations // [])[] | select(.projectId == $p) | .organization' | head -n1)
    [ -z "$ORG" ] && fail "no Apigee organization is linked to project '$GCP_PROJECT_ID'." \
        "This bundle's fixtures need a pre-existing shared Apigee X org." \
        "It is provisioned by the gcp-apigee-environment-health bundle's bootstrap," \
        "takes ~45 minutes, and is one-per-project -- it is NOT created here." \
        "Set APIGEE_ORG if the org belongs to a different project."
fi
echo "Preflight: using Apigee organization '$ORG'."

# --- at least one environment exists ----------------------------------------
resp=$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/environments")
code="${resp##*$'\n'}"; body="${resp%$'\n'*}"
[ "${code:0:1}" != "2" ] && fail "listing environments for org '$ORG' returned HTTP $code." \
    "$(printf '%s' "$body" | jq -r 'if type=="object" then (.error.message // "no error message") else "unexpected body" end' 2>/dev/null)" \
    "Confirm the org name and that the service account can read it."

env_count=$(printf '%s' "$body" | jq 'if type=="array" then length elif type=="object" then ((.environments // []) | length) else 0 end' 2>/dev/null || echo 0)
[ "$env_count" -eq 0 ] && fail "org '$ORG' has no environments." \
    "Proxy fixtures must be deployed to an environment." \
    "Provision environments via the gcp-apigee-environment-health bootstrap first."

echo "Preflight: $env_count environment(s) available. Prerequisites satisfied."
