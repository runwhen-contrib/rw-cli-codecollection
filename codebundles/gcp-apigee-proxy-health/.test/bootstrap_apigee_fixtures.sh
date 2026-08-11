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
#   ${SUFFIX}-proxy-healthy   - deployed READY on latest revision in every env
#   ${SUFFIX}-proxy-drift     - test env on rev 1, prod env on rev 2 (drift)
#   ${SUFFIX}-proxy-failed    - a broken newest revision that fails to deploy
#                                     while the old revision keeps serving
#   ${SUFFIX}-proxy-orphaned  - proxy with revisions but NO deployment anywhere
#
# Every fixture carries FIXTURE_SUFFIX. The Apigee organization is SHARED with
# the sibling gcp-apigee-* bundles (an org is one-per-GCP-project), so fixed
# names would mean this bundle cannot run twice concurrently, a failed run would
# leave fixtures the next run silently adopts instead of creating, and teardown
# would have nothing to query for leftovers.
#
# REQUIRED ENV:
#   GCP_PROJECT_ID  - GCP project owning the Apigee org (used to resolve org)
#   APIGEE_ORG      - optional; Apigee org name (resolved if empty). Accepted
#                     either bare ("my-org") or prefixed ("organizations/my-org")
#   FIXTURE_SUFFIX - fixture suffix (default test001)
#
# PREREQUISITES: gcloud authenticated service account with apigee admin access,
#   curl, jq, zip. `gcloud auth print-access-token` must work.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
BASE="https://apigee.googleapis.com/v1"
TMP_ROOT="${TMP_ROOT:-/tmp/apigee-fixtures}"
SUFFIX="${FIXTURE_SUFFIX:-${TF_VAR_resource_suffix:-test001}}"

# Tools are checked up front rather than discovered mid-run. `zip` in
# particular is absent from the standard devtools image, and when it failed
# inside build_bundle the script carried on and printed "Deployed ... rev  to
# ..." for three fixtures that were never created.
for tool in curl jq zip; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: $tool is required to build Apigee fixtures but is not installed." >&2
        echo "       See .test/README.md 'Requirements'. Note that zip is missing from" >&2
        echo "       ghcr.io/runwhen-contrib/codecollection-devtools." >&2
        exit 1
    }
done

TOKEN="${APIGEE_TOKEN:-$(gcloud auth print-access-token 2>/dev/null || true)}"
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
    # Fail hard. A bundle that was not built cannot be imported, so continuing
    # produces a chain of false "Deployed ..." lines for fixtures that do not
    # exist -- which is what a caller reads as "the fixtures are ready".
    if ! ( cd "$TMP_ROOT" && zip -qr "${tree}.zip" "$tree" ); then
        echo "ERROR: failed to build the proxy bundle for '$name' (zip returned non-zero)." >&2
        exit 1
    fi
    if [ ! -s "$TMP_ROOT/${tree}.zip" ]; then
        echo "ERROR: proxy bundle for '$name' is missing or empty: $TMP_ROOT/${tree}.zip" >&2
        exit 1
    fi
    echo "$TMP_ROOT/${tree}.zip"
}

# ----------------------------------------------------------------------
# import + create a new revision, returning the revision number
# ----------------------------------------------------------------------
# Returns the revision number, or exits non-zero. There is deliberately no
# fallback: the previous `.revision // "0"` plus `[ "$rev" = "0" ] && rev=1`
# turned a failed import into a fabricated revision 1 and then "deployed" it,
# while a curl that produced no output at all left the revision EMPTY and the
# script announced `Deployed ... rev  to ...`. Both read as success.
import_revision() {
    local name="$1" bundle_zip="$2" resp rev
    # If proxy does not exist, import under action=import creates it (rev 1).
    resp=$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" \
        -F "file=@$bundle_zip" \
        "$BASE/organizations/$ORG/apis?action=import&name=$name") || {
        echo "ERROR: importing '$name' failed (curl returned non-zero)." >&2
        exit 1
    }
    rev=$(printf '%s' "$resp" | jq -r 'if type=="object" then (.revision // empty) else empty end' 2>/dev/null || true)
    case "$rev" in
        ''|*[!0-9]*)
            echo "ERROR: importing '$name' returned no usable revision." >&2
            echo "       response: $(printf '%s' "$resp" | head -c 300)" >&2
            exit 1
            ;;
    esac
    printf '%s' "$rev"
}

# ----------------------------------------------------------------------
# deploy a revision to an environment
# ----------------------------------------------------------------------
deploy_revision() {
    local name="$1" env="$2" rev="$3" code
    # Refuse to announce a deployment of a revision that does not exist. The
    # empty-rev case is exactly what printed three false "Deployed" lines.
    case "$rev" in
        ''|*[!0-9]*)
            echo "ERROR: refusing to deploy '$name' to '$env' with revision '$rev'." >&2
            exit 1
            ;;
    esac
    code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
        "$BASE/organizations/$ORG/environments/$env/apis/$name/revisions/$rev/deployments?override=true")
    case "$code" in
        2*) echo "Deployed $name rev $rev to $env" ;;
        *)  echo "ERROR: deploying $name rev $rev to $env returned HTTP $code." >&2; exit 1 ;;
    esac
}

env=$(echo "$ENVS" | head -n1)
env2=$(echo "$ENVS" | sed -n '2p')

echo "== Fixture: ${SUFFIX}-proxy-healthy (deployed READY on latest in every env) =="
bundle=$(build_bundle "${SUFFIX}-proxy-healthy" "${SUFFIX}-proxy-healthy-apiproxy")
rev=$(import_revision "${SUFFIX}-proxy-healthy" "$bundle")
for e in $ENVS; do deploy_revision "${SUFFIX}-proxy-healthy" "$e" "$rev"; done

echo "== Fixture: ${SUFFIX}-proxy-drift (test on rev1, prod on rev2) =="
bundle=$(build_bundle "${SUFFIX}-proxy-drift" "${SUFFIX}-proxy-drift-apiproxy")
rev1=$(import_revision "${SUFFIX}-proxy-drift" "$bundle")
bundle2=$(build_bundle "${SUFFIX}-proxy-drift" "${SUFFIX}-proxy-drift-apiproxy")
rev2=$(import_revision "${SUFFIX}-proxy-drift" "$bundle2")
deploy_revision "${SUFFIX}-proxy-drift" "$env" "$rev1"   # older revision in first env
if [ -n "$env2" ]; then
    deploy_revision "${SUFFIX}-proxy-drift" "$env2" "$rev2"  # latest in second env -> drift
else
    deploy_revision "${SUFFIX}-proxy-drift" "$env" "$rev2"  # override to latest -> no drift; see note
fi

echo "== Fixture: ${SUFFIX}-proxy-failed (broken newest revision fails to deploy) =="
bundle=$(build_bundle "${SUFFIX}-proxy-failed" "${SUFFIX}-proxy-failed-apiproxy")
rev1=$(import_revision "${SUFFIX}-proxy-failed" "$bundle")
deploy_revision "${SUFFIX}-proxy-failed" "$env" "$rev1"      # good rev serves
bad_bundle=$(build_bundle "${SUFFIX}-proxy-failed" "${SUFFIX}-proxy-failed-apiproxy" 1)
# The IMPORT must succeed -- a broken revision that was never uploaded leaves
# this fixture healthy, which silently removes the only thing it tests. Use the
# same hard-failing helper as every other import.
bad_rev=$(import_revision "${SUFFIX}-proxy-failed" "$bad_bundle")

# The DEPLOY, by contrast, is expected to end badly: that is the fixture. Apigee
# usually accepts the request and the deployment then settles into ERROR, but it
# may also reject it outright. Either is fine here, so the status is reported
# rather than enforced -- and the ground-truth block below is what actually
# decides whether the fixture came out broken the way it claims.
bad_code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
    "$BASE/organizations/$ORG/environments/$env/apis/${SUFFIX}-proxy-failed/revisions/$bad_rev/deployments?override=true" || echo "000")
echo "Attempted (broken) deploy of rev $bad_rev to $env -- HTTP $bad_code (a failure here is expected)"

echo "== Fixture: ${SUFFIX}-proxy-orphaned (uploaded, never deployed) =="
bundle=$(build_bundle "${SUFFIX}-proxy-orphaned" "${SUFFIX}-proxy-orphaned-apiproxy")
rev=$(import_revision "${SUFFIX}-proxy-orphaned" "$bundle")
echo "Imported ${SUFFIX}-proxy-orphaned rev $rev but deliberately not deployed."

echo ""
echo "Deployments now in org '$ORG' carrying suffix '$SUFFIX':"
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/deployments" \
    | jq -r --arg s "$SUFFIX" \
      '(.deployments // [])[] | select(.apiProxy | endswith($s))
       | "  \(.apiProxy) / \(.environment) / rev \(.revision)"'

# -----------------------------------------------------------------------------
# Ground truth. Every assertion below states the property a check depends on;
# if one fails the fixture is not broken the way it claims and the corresponding
# check would pass for the wrong reason.
# -----------------------------------------------------------------------------
echo "Verifying fixture ground truth"
gt_failures=0
gt() {
  if [ "$2" = "$3" ]; then
    echo "    ✓ $1"
  else
    echo "    ✗ $1 (expected '$3', got '$2')"
    gt_failures=$((gt_failures + 1))
  fi
}

# Fetch and filter kept separate: a failed listing must not read as "the fixture
# is missing", nor as "the fixture is fine".
if ! proxies_json="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/apis?includeRevisions=true")"; then
  echo "ERROR: could not list API proxies to verify fixture ground truth." >&2
  exit 1
fi
if ! deployments_json="$(curl -fsS -H "Authorization: Bearer $TOKEN" "$BASE/organizations/$ORG/deployments")"; then
  echo "ERROR: could not list deployments to verify fixture ground truth." >&2
  exit 1
fi

for f in healthy drift failed orphaned; do
  gt "${SUFFIX}-proxy-$f exists" \
    "$(printf '%s' "$proxies_json" | jq -r --arg n "${SUFFIX}-proxy-$f" '[.proxies[]?|select(.name==$n)]|length')" "1"
done

gt "${SUFFIX}-proxy-drift runs >1 distinct revision across environments" \
  "$(printf '%s' "$deployments_json" | jq -r --arg n "${SUFFIX}-proxy-drift" \
     '[.deployments[]?|select(.apiProxy==$n)|.revision]|unique|length > 1')" "true"

gt "${SUFFIX}-proxy-orphaned is deployed nowhere" \
  "$(printf '%s' "$deployments_json" | jq -r --arg n "${SUFFIX}-proxy-orphaned" \
     '[.deployments[]?|select(.apiProxy==$n)]|length')" "0"

gt "${SUFFIX}-proxy-healthy is deployed somewhere" \
  "$(printf '%s' "$deployments_json" | jq -r --arg n "${SUFFIX}-proxy-healthy" \
     '[.deployments[]?|select(.apiProxy==$n)]|length > 0')" "true"

# The failed fixture must have at least one deployment that never reached READY.
# state[] lives only on the per-revision status view, so it is read per
# deployment rather than from the org-wide list.
failed_not_ready="false"
while read -r dep; do
  [ -z "$dep" ] && continue
  e="$(printf '%s' "$dep" | jq -r '.environment')"
  r="$(printf '%s' "$dep" | jq -r '.revision')"
  if ! st_body="$(curl -fsS -H "Authorization: Bearer $TOKEN" \
      "$BASE/organizations/$ORG/environments/$e/apis/${SUFFIX}-proxy-failed/revisions/$r/deployments")"; then
    echo "    warning: could not read status of ${SUFFIX}-proxy-failed rev $r in $e" >&2
    continue
  fi
  st="$(printf '%s' "$st_body" | jq -r '.state // "UNKNOWN"')"
  [ "$st" != "READY" ] && failed_not_ready="true"
done < <(printf '%s' "$deployments_json" | jq -c --arg n "${SUFFIX}-proxy-failed" '.deployments[]?|select(.apiProxy==$n)')

gt "${SUFFIX}-proxy-failed has a deployment that never reached READY" \
  "$failed_not_ready" "true"

if [ "$gt_failures" -gt 0 ]; then
  echo
  echo "ERROR: $gt_failures fixture(s) are not in the state they claim." >&2
  echo "       Running the checks against them would prove nothing. Fix or re-create the fixtures." >&2
  exit 1
fi

echo "Fixtures created and verified."
