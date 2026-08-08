#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# bootstrap_apigee_fixtures.sh
# Creates the Apigee test fixtures used by the gcp-apigee-proxy-health CodeBundle
# in the shared Apigee X test organization. Since proxy deployment is NOT well
# handled by Terraform (proxies are uploaded as zipped bundles), this script
# uploads/deploys proxies and revisions via the Apigee Management REST API.
#
# Fixtures created (deliberately include broken cases so the CodeBundle's
# detection paths are exercised -- healthy-only fixtures do not cover the paths
# that matter):
#
#   apigee-health-healthy      - deployed READY on latest revision in every env
#   apigee-health-drift        - test env on rev 1, prod env on rev 2 (drift)
#   apigee-health-failed       - a broken newest revision that fails to deploy
#                                while the old revision keeps serving
#   apigee-health-orphaned     - proxy with revisions but NO deployment anywhere
#
# REQUIRED ENV:
#   GCP_PROJECT_ID - GCP project owning the Apigee org (used to resolve org)
#   APIGEE_ORG     - optional; Apigee org name (resolved if empty)
#
# PREREQUISITES: gcloud authenticated service account with apigee admin access,
#   curl, jq, zip. `gcloud auth print-access-token` must work.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
BASE="https://apigee.googleapis.com/v1"
TMP_ROOT="${TMP_ROOT:-/tmp/apigee-fixtures}"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
[ -z "$TOKEN" ] && { echo "No access token. Authenticate gcloud first."; exit 1; }

if [ -n "${APIGEE_ORG:-}" ]; then
    ORG="$APIGEE_ORG"
else
    ORG=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations" \
        | jq -r --arg p "$GCP_PROJECT_ID" '(.organizations // [])[] | select(.projectId == $p) | .organization' | head -n1)
fi
[ -z "$ORG" ] && { echo "Could not resolve Apigee org for project $GCP_PROJECT_ID."; exit 1; }
echo "Using Apigee org: $ORG"

ENVS=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/environments" | jq -r '.environments // [] | .[]')
[ -z "$ENVS" ] && { echo "No environments found in org $ORG. Provision environments first (see the env health bootstrap)."; exit 1; }
echo "Environments: $(echo "$ENVS" | tr '\n' ' ')"

mkdir -p "$TMP_ROOT"

# ----------------------------------------------------------------------
# build minimal proxy bundle for a given revision. A bundle consists of a
# ProxyEndpoint + TargetEndpoint. Optionally corrupt (empty) the bundle to make
# a revision that fails to deploy.
# ----------------------------------------------------------------------
build_bundle() {
    local name="$1" out_dir="$2" corrupt="${3:-0}"
    rm -rf "$out_dir"
    mkdir -p "$out_dir/apiproxy"
    cat > "$out_dir/apiproxy/$name.xml" <<EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<APIProxy revision="1" name="$name">
  <Description>RunWhen health test fixture for $name</Description>
  <Policies/>
  <ProxyEndpoints>
    <ProxyEndpoint name="default">
      <HTTPProxyConnection>
        <BasePath>/${name}</BasePath>
      </HTTPProxyConnection>
      <RouteRule name="default"><TargetEndpoint>default</TargetEndpoint></RouteRule>
    </ProxyEndpoint>
  </ProxyEndpoints>
  <TargetEndpoints>
    <TargetEndpoint name="default">
      <HTTPTargetConnection>
        <URL>http://httpbin.org/anything</URL>
      </HTTPTargetConnection>
    </TargetEndpoint>
  </TargetEndpoints>
  <Spec/>
</APIProxy>
EOF
    tree=$(basename "$out_dir")
    if [ "$corrupt" = "1" ]; then
        # A broken revision: references a policy that does not exist -> import
        # succeeds but runtime deployment fails (missing resource).
        sed -i 's#<Policies/>#<Policies><Policy>NonExistentPolicy</Policy></Policies>#' \
            "$out_dir/apiproxy/$name.xml"
    fi
    ( cd "$TMP_ROOT" && zip -qr "${tree}.zip" "$tree" )
    echo "$TMP_ROOT/${tree}.zip"
}

# ----------------------------------------------------------------------
# import + create a new revision, returning the revision number
# ----------------------------------------------------------------------
import_revision() {
    local name="$1" bundle_zip="$2"
    # If proxy does not exist, import under action=import creates it (rev 1).
    resp=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        -F "file=@$bundle_zip" \
        "$BASE/organizations/$ORG/apis?action=import&name=$name")
    echo "$resp" | jq -r '.revision // "0"'
}

# ----------------------------------------------------------------------
# deploy a revision to an environment
# ----------------------------------------------------------------------
deploy_revision() {
    local name="$1" env="$2" rev="$3"
    curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        "$BASE/organizations/$ORG/environments/$env/apis/$name/revisions/$rev/deployments?override=true" \
        > /dev/null || true
    echo "Deployed $name rev $rev to $env"
}

env=$(echo "$ENVS" | head -n1)
env2=$(echo "$ENVS" | sed -n '2p')

echo "== Fixture: apigee-health-healthy (deployed READY on latest in every env) =="
bundle=$(build_bundle "apigee-health-healthy" "apigee-health-healthy-apiproxy")
rev=$(import_revision "apigee-health-healthy" "$bundle")
[ "$rev" = "0" ] && rev=1
for e in $ENVS; do deploy_revision "apigee-health-healthy" "$e" "$rev"; done

echo "== Fixture: apigee-health-drift (test on rev1, prod on rev2) =="
bundle=$(build_bundle "apigee-health-drift" "apigee-health-drift-apiproxy")
rev1=$(import_revision "apigee-health-drift" "$bundle")
[ "$rev1" = "0" ] && rev1=1
bundle2=$(build_bundle "apigee-health-drift" "apigee-health-drift-apiproxy")
rev2=$(import_revision "apigee-health-drift" "$bundle2")
[ "$rev2" = "0" ] && rev2=2
deploy_revision "apigee-health-drift" "$env" "$rev1"   # older revision in first env
if [ -n "$env2" ]; then
    deploy_revision "apigee-health-drift" "$env2" "$rev2"  # latest in second env -> drift
else
    deploy_revision "apigee-health-drift" "$env" "$rev2"  # override to latest -> no drift; see note
fi

echo "== Fixture: apigee-health-failed (broken newest revision fails to deploy) =="
bundle=$(build_bundle "apigee-health-failed" "apigee-health-failed-apiproxy")
rev1=$(import_revision "apigee-health-failed" "$bundle")
[ "$rev1" = "0" ] && rev1=1
deploy_revision "apigee-health-failed" "$env" "$rev1"      # good rev serves
bad_bundle=$(build_bundle "apigee-health-failed" "apigee-health-failed-apiproxy" 1)
resp=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -F "file=@$bad_bundle" \
    "$BASE/organizations/$ORG/apis?name=apigee-health-failed&action=import")
bad_rev=$(echo "$resp" | jq -r '.revision // ""')
if [ -n "$bad_rev" ]; then
    # Attempt to deploy the broken revision -- expected to error in runtime.
    curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        "$BASE/organizations/$ORG/environments/$env/apis/apigee-health-failed/revisions/$bad_rev/deployments?override=true" > /dev/null || true
    echo "Attempted (broken) deploy of $bad_rev to $env"
fi

echo "== Fixture: apigee-health-orphaned (uploaded, never deployed) =="
bundle=$(build_bundle "apigee-health-orphaned" "apigee-health-orphaned-apiproxy")
rev=$(import_revision "apigee-health-orphaned" "$bundle")
echo "Imported apigee-health-orphaned rev $rev but deliberately not deployed."

echo "Bootstrap complete. Review deployments:"
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/deployments" \
    | jq -r '.deployments[] | "\(.apiProxy) / \(.environment) / rev \(.revision) / \(.state)"'
