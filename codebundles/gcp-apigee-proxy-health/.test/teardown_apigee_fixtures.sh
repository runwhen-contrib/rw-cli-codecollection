#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# teardown_apigee_fixtures.sh
# Undeploys and deletes every API proxy in the shared Apigee organization whose
# name carries RESOURCE_SUFFIX, then ASSERTS that none survive.
#
# The assertion is the point. The Apigee organization is long-lived and shared
# with the sibling gcp-apigee-* bundles, so leftovers are not cleaned up by
# anything else: they linger, and the next run silently adopts them instead of
# creating fresh ones -- at which point the fixtures under test are whatever the
# last failed run happened to leave behind.
#
# Leftovers are queried from the PROVIDER, not from local state. A proxy created
# but absent from any state file is invisible to a state-based check and would
# survive a "successful" teardown.
#
# REQUIRED ENV:
#   GCP_PROJECT_ID  - GCP project owning the Apigee org
#   APIGEE_ORG      - optional; bare or "organizations/"-prefixed
#   RESOURCE_SUFFIX - fixture suffix (default test001)
#
# Exits non-zero if anything bearing the suffix still exists afterwards.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
BASE="https://apigee.googleapis.com/v1"
SUFFIX="${RESOURCE_SUFFIX:-${TF_VAR_resource_suffix:-test001}}"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
[ -z "$TOKEN" ] && { echo "ERROR: no gcloud access token; teardown cannot run." >&2; exit 1; }

if [ -n "${APIGEE_ORG:-}" ]; then
    ORG="${APIGEE_ORG#organizations/}"
else
    ORG=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations" \
        | jq -r --arg p "$GCP_PROJECT_ID" '(.organizations // [])[] | select(.projectId == $p) | .organization' | head -n1)
fi
[ -z "$ORG" ] && { echo "ERROR: could not resolve Apigee org for project $GCP_PROJECT_ID." >&2; exit 1; }
echo "Tearing down fixtures with suffix '$SUFFIX' in org '$ORG'."

api_get() { curl -s -H "Authorization: Bearer $TOKEN" "$1"; }

list_suffixed_proxies() {
    api_get "$BASE/organizations/$ORG/apis" \
        | jq -r --arg s "$SUFFIX" '(.proxies // [])[] | select(.name | endswith($s)) | .name'
}

# --- undeploy every deployment of a suffixed proxy ---------------------------
api_get "$BASE/organizations/$ORG/deployments" \
    | jq -r --arg s "$SUFFIX" \
      '(.deployments // [])[] | select(.apiProxy | endswith($s))
       | "\(.apiProxy)\t\(.environment)\t\(.revision)"' \
    | while IFS=$'\t' read -r proxy env rev; do
        [ -z "$proxy" ] && continue
        echo "  undeploying $proxy rev $rev from $env"
        curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
            "$BASE/organizations/$ORG/environments/$env/apis/$proxy/revisions/$rev/deployments" \
            > /dev/null || true
    done

# --- delete the proxies ------------------------------------------------------
for proxy in $(list_suffixed_proxies); do
    echo "  deleting proxy $proxy"
    curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
        "$BASE/organizations/$ORG/apis/$proxy" > /dev/null || true
done

# --- assert nothing survives, queried from the provider ----------------------
echo ""
echo "Verifying teardown against the Apigee API..."
remaining_proxies=$(list_suffixed_proxies | grep -c . || true)
remaining_deploys=$(api_get "$BASE/organizations/$ORG/deployments" \
    | jq --arg s "$SUFFIX" '[(.deployments // [])[] | select(.apiProxy | endswith($s))] | length')

echo "  proxies bearing '$SUFFIX':     $remaining_proxies"
echo "  deployments bearing '$SUFFIX': $remaining_deploys"

if [ "$remaining_proxies" -ne 0 ] || [ "$remaining_deploys" -ne 0 ]; then
    echo "" >&2
    echo "TEARDOWN FAILED: resources bearing suffix '$SUFFIX' survive in org '$ORG'." >&2
    list_suffixed_proxies | sed 's/^/  leftover proxy: /' >&2
    echo "They will be silently adopted by the next run. Remove them before re-running." >&2
    exit 1
fi

echo "Teardown verified: zero resources bearing suffix '$SUFFIX' remain."
