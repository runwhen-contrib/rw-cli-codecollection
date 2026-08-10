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
#   apigee-health-healthy-$SUFFIX   - deployed READY on latest revision in every env
#   apigee-health-drift-$SUFFIX     - test env on rev 1, prod env on rev 2 (drift)
#   apigee-health-failed-$SUFFIX    - a broken newest revision that fails to deploy
#                                     while the old revision keeps serving
#   apigee-health-orphaned-$SUFFIX  - proxy with revisions but NO deployment anywhere
#
# Every fixture carries RESOURCE_SUFFIX. The Apigee organization is SHARED with
# the sibling gcp-apigee-* bundles (an org is one-per-GCP-project), so fixed
# names would mean this bundle cannot run twice concurrently, a failed run would
# leave fixtures the next run silently adopts instead of creating, and teardown
# would have nothing to query for leftovers.
#
# REQUIRED ENV:
#   GCP_PROJECT_ID  - GCP project owning the Apigee org (used to resolve org)
#   APIGEE_ORG      - optional; Apigee org name (resolved if empty). Accepted
#                     either bare ("my-org") or prefixed ("organizations/my-org")
#   RESOURCE_SUFFIX - fixture suffix (default test001)
#
# PREREQUISITES: gcloud authenticated service account with apigee admin access,
#   curl, jq, zip. `gcloud auth print-access-token` must work.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
BASE="https://apigee.googleapis.com/v1"
TMP_ROOT="${TMP_ROOT:-/tmp/apigee-fixtures}"
SUFFIX="${RESOURCE_SUFFIX:-${TF_VAR_resource_suffix:-test001}}"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
[ -z "$TOKEN" ] && { echo "No access token. Authenticate gcloud first."; exit 1; }

if [ -n "${APIGEE_ORG:-}" ]; then
    # The sibling bundles disagree on whether this carries the "organizations/"
    # prefix; accept either rather than building /organizations/organizations/x.
    ORG="${APIGEE_ORG#organizations/}"
else
    ORG=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations" \
        | jq -r --arg p "$GCP_PROJECT_ID" '(.organizations // [])[] | select(.projectId == $p) | .organization' | head -n1)
fi
[ -z "$ORG" ] && { echo "Could not resolve Apigee org for project $GCP_PROJECT_ID."; exit 1; }
echo "Using Apigee org: $ORG"

# /environments is an Edge-compatibility path that returns a BARE array of
# names, not {"environments":[...]}. Indexing that with a string is a jq error,
# and the empty result then reads as "no environments" rather than "the parse
# failed". Accept both shapes.
ENVS=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/environments" \
    | jq -r 'if type=="array" then .[] elif type=="object" then ((.environments // [])[]) else empty end')
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
        # `sed -i` without a suffix is GNU-only; BSD sed (macOS) treats the next
        # argument as the backup extension and eats the script.
        sed 's#<Policies/>#<Policies><Policy>NonExistentPolicy</Policy></Policies>#' \
            "$out_dir/apiproxy/$name.xml" > "$out_dir/apiproxy/$name.xml.tmp"
        mv "$out_dir/apiproxy/$name.xml.tmp" "$out_dir/apiproxy/$name.xml"
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

echo "== Fixture: apigee-health-healthy-${SUFFIX} (deployed READY on latest in every env) =="
bundle=$(build_bundle "apigee-health-healthy-${SUFFIX}" "apigee-health-healthy-${SUFFIX}-apiproxy")
rev=$(import_revision "apigee-health-healthy-${SUFFIX}" "$bundle")
[ "$rev" = "0" ] && rev=1
for e in $ENVS; do deploy_revision "apigee-health-healthy-${SUFFIX}" "$e" "$rev"; done

echo "== Fixture: apigee-health-drift-${SUFFIX} (test on rev1, prod on rev2) =="
bundle=$(build_bundle "apigee-health-drift-${SUFFIX}" "apigee-health-drift-${SUFFIX}-apiproxy")
rev1=$(import_revision "apigee-health-drift-${SUFFIX}" "$bundle")
[ "$rev1" = "0" ] && rev1=1
bundle2=$(build_bundle "apigee-health-drift-${SUFFIX}" "apigee-health-drift-${SUFFIX}-apiproxy")
rev2=$(import_revision "apigee-health-drift-${SUFFIX}" "$bundle2")
[ "$rev2" = "0" ] && rev2=2
deploy_revision "apigee-health-drift-${SUFFIX}" "$env" "$rev1"   # older revision in first env
if [ -n "$env2" ]; then
    deploy_revision "apigee-health-drift-${SUFFIX}" "$env2" "$rev2"  # latest in second env -> drift
else
    deploy_revision "apigee-health-drift-${SUFFIX}" "$env" "$rev2"  # override to latest -> no drift; see note
fi

echo "== Fixture: apigee-health-failed-${SUFFIX} (broken newest revision fails to deploy) =="
bundle=$(build_bundle "apigee-health-failed-${SUFFIX}" "apigee-health-failed-${SUFFIX}-apiproxy")
rev1=$(import_revision "apigee-health-failed-${SUFFIX}" "$bundle")
[ "$rev1" = "0" ] && rev1=1
deploy_revision "apigee-health-failed-${SUFFIX}" "$env" "$rev1"      # good rev serves
bad_bundle=$(build_bundle "apigee-health-failed-${SUFFIX}" "apigee-health-failed-${SUFFIX}-apiproxy" 1)
resp=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -F "file=@$bad_bundle" \
    "$BASE/organizations/$ORG/apis?name=apigee-health-failed-${SUFFIX}&action=import")
bad_rev=$(echo "$resp" | jq -r '.revision // ""')
if [ -n "$bad_rev" ]; then
    # Attempt to deploy the broken revision -- expected to error in runtime.
    curl -s -X POST -H "Authorization: Bearer $TOKEN" \
        "$BASE/organizations/$ORG/environments/$env/apis/apigee-health-failed-${SUFFIX}/revisions/$bad_rev/deployments?override=true" > /dev/null || true
    echo "Attempted (broken) deploy of $bad_rev to $env"
fi

echo "== Fixture: apigee-health-orphaned-${SUFFIX} (uploaded, never deployed) =="
bundle=$(build_bundle "apigee-health-orphaned-${SUFFIX}" "apigee-health-orphaned-${SUFFIX}-apiproxy")
rev=$(import_revision "apigee-health-orphaned-${SUFFIX}" "$bundle")
echo "Imported apigee-health-orphaned-${SUFFIX} rev $rev but deliberately not deployed."

echo ""
echo "Deployments now in org '$ORG' carrying suffix '$SUFFIX':"
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/deployments" \
    | jq -r --arg s "$SUFFIX" \
      '(.deployments // [])[] | select(.apiProxy | endswith($s))
       | "  \(.apiProxy) / \(.environment) / rev \(.revision)"'

# --- fixture ground truth ----------------------------------------------------
# Assert the fixtures are broken the way they claim. A "broken" fixture that
# provisions healthy silently removes the only thing under test, and the live
# run then passes while verifying nothing.
echo ""
echo "Verifying fixture ground truth..."
proxies=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/apis?includeRevisions=true" \
          | jq -c '.proxies // []')
deployments=$(curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/deployments" \
              | jq -c '.deployments // []')

gt_failures=0
gt_check() {
    local label="$1" ok="$2" detail="$3"
    if [ "$ok" = "1" ]; then
        echo "  OK   $label"
    else
        echo "  FAIL $label -- $detail" >&2
        gt_failures=$((gt_failures + 1))
    fi
}

# every fixture exists
for f in healthy drift failed orphaned; do
    name="apigee-health-${f}-${SUFFIX}"
    exists=$(printf '%s' "$proxies" | jq --arg n "$name" '[.[] | select(.name == $n)] | length')
    gt_check "$name exists" "$([ "$exists" -gt 0 ] && echo 1 || echo 0)" "proxy not found in the org"
done

# drift fixture really runs different revisions in different environments
drift_revs=$(printf '%s' "$deployments" | jq --arg n "apigee-health-drift-${SUFFIX}" \
             '[.[] | select(.apiProxy == $n) | .revision] | unique | length')
gt_check "apigee-health-drift-${SUFFIX} has >1 distinct deployed revision" \
    "$([ "${drift_revs:-0}" -gt 1 ] && echo 1 || echo 0)" \
    "found ${drift_revs:-0} distinct revision(s); the drift fixture needs two environments"

# orphaned fixture really has no deployment
orph=$(printf '%s' "$deployments" | jq --arg n "apigee-health-orphaned-${SUFFIX}" \
       '[.[] | select(.apiProxy == $n)] | length')
gt_check "apigee-health-orphaned-${SUFFIX} has no deployment" \
    "$([ "${orph:-0}" -eq 0 ] && echo 1 || echo 0)" \
    "it is deployed to ${orph} environment(s); it must be deployed nowhere"

# failed fixture really has a revision that did not reach READY
failed_name="apigee-health-failed-${SUFFIX}"
failed_bad=0
while read -r dep; do
    [ -z "$dep" ] && continue
    e=$(printf '%s' "$dep" | jq -r '.environment')
    r=$(printf '%s' "$dep" | jq -r '.revision')
    st=$(curl -s -H "Authorization: Bearer $TOKEN" \
         "$BASE/organizations/$ORG/environments/$e/apis/$failed_name/revisions/$r/deployments" \
         | jq -r '.state // "UNKNOWN"')
    [ "$st" != "READY" ] && failed_bad=1
done < <(printf '%s' "$deployments" | jq -c --arg n "$failed_name" '.[] | select(.apiProxy == $n)')
gt_check "$failed_name has a deployment not in READY state" "$failed_bad" \
    "every deployment reached READY; the broken-revision fixture did not break"

echo ""
if [ "$gt_failures" -gt 0 ]; then
    echo "Bootstrap FAILED ground truth: $gt_failures fixture(s) are not broken the way they claim." >&2
    echo "A live run against these fixtures would verify nothing. Fix before proceeding." >&2
    exit 1
fi
echo "Bootstrap complete. All fixtures match their claimed state."
