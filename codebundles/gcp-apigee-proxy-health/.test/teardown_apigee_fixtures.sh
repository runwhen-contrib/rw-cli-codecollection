#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# teardown_apigee_fixtures.sh
#
# Undeploys and deletes the API proxy fixtures created by
# bootstrap_apigee_fixtures.sh from the shared test organization, then VERIFIES
# that nothing carrying the fixture suffix survives. Leftovers in a shared org
# are not harmless: an abandoned proxy is silently adopted by the next run
# instead of being created, so the fixtures under test become whatever the last
# failed run happened to leave behind.
#
# Leftovers are queried from the PROVIDER, not from local state. Terraform never
# created these objects -- proxies are uploaded over the REST API -- so no state
# file records them and `terraform destroy` cannot see them.
#
# Exits non-zero if anything with the suffix is still present afterwards.
# -----------------------------------------------------------------------------
set -uo pipefail

: "${APIGEE_ORG:=${TF_VAR_org_id:-}}"
: "${APIGEE_ORG:?Must set APIGEE_ORG (or TF_VAR_org_id)}"
# The URLs below already carry the "organizations/" segment; the sibling bundles
# name the same org in the prefixed form, so accept both spellings.
APIGEE_ORG="${APIGEE_ORG#organizations/}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required." >&2; exit 1; }
done

BASE="https://apigee.googleapis.com/v1"
ORG_URL="$BASE/organizations/$APIGEE_ORG"
TOKEN="${APIGEE_TOKEN:-$(gcloud auth print-access-token)}"
[ -n "$TOKEN" ] || { echo "ERROR: could not obtain an access token." >&2; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")

suffix="${FIXTURE_SUFFIX:-${TF_VAR_resource_suffix:-test001}}"

echo "Removing Apigee proxy fixtures (suffix: $suffix) from org: $APIGEE_ORG"

# api_delete: 2xx and 404 are both fine (absent is the desired end state); any
# other status is reported. Deletion failures are not fatal on their own because
# the verification pass below is what actually decides.
api_delete() {
  local url="$1" code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "${AUTH[@]}" "$url")"
  case "$code" in
    2*|404) ;;
    *) echo "    warning: DELETE $url returned HTTP $code" >&2 ;;
  esac
}

# --- Undeploy every deployment of a suffixed proxy ---------------------------
# Fetch and filter are kept separate here too: a failed deployments listing must
# not read as "nothing to undeploy".
if ! deployments_body="$(curl -fsS "${AUTH[@]}" "$ORG_URL/deployments")"; then
  echo "    warning: could not list deployments; proceeding to proxy deletion" >&2
  deployments_body='{}'
fi

printf '%s' "$deployments_body" \
  | jq -r --arg s "$suffix" \
    '(.deployments // [])[] | select(.apiProxy | startswith($s))
     | "\(.apiProxy)\t\(.environment)\t\(.revision)"' \
  | while IFS=$'\t' read -r proxy env rev; do
      [ -z "$proxy" ] && continue
      echo "    undeploying $proxy rev $rev from $env"
      api_delete "$ORG_URL/environments/$env/apis/$proxy/revisions/$rev/deployments"
    done

# --- Delete the proxies ------------------------------------------------------
if ! apis_body="$(curl -fsS "${AUTH[@]}" "$ORG_URL/apis")"; then
  echo "    warning: could not list API proxies before deletion" >&2
  apis_body='{}'
fi

printf '%s' "$apis_body" \
  | jq -r --arg s "$suffix" '(.proxies // [])[] | .name | select(startswith($s))' \
  | while read -r proxy; do
      [ -z "$proxy" ] && continue
      echo "    deleting proxy $proxy"
      api_delete "$ORG_URL/apis/$proxy"
    done

# --- Verify against the provider, not against local state --------------------
echo "Verifying teardown"
leftovers=0

# The fetch and the filter are kept separate on purpose. Piping curl into jq and
# swallowing errors would turn "could not query the org" into an empty result,
# i.e. into "nothing left over" -- the exact blind pass this step exists to
# prevent.
if ! proxies_body="$(curl -fsS "${AUTH[@]}" "$ORG_URL/apis")"; then
  echo "    ✗ could not list API proxies to verify teardown"
  leftovers=$((leftovers + 1))
else
  remaining_proxies="$(printf '%s' "$proxies_body" \
    | jq -r --arg s "$suffix" '[.proxies[]? | (if type == "string" then . else .name end) | select(startswith($s))] | .[]')"
  if [ -n "$remaining_proxies" ]; then
    # Indent with sed rather than an unquoted expansion: word splitting would
    # report one name containing a space as two leftovers.
    echo "    ✗ API proxies still present:"; printf '%s\n' "$remaining_proxies" | sed 's/^/        /'
    leftovers=$((leftovers + 1))
  else
    echo "    ✓ no API proxies with suffix $suffix remain"
  fi
fi

if ! deploy_body="$(curl -fsS "${AUTH[@]}" "$ORG_URL/deployments")"; then
  echo "    ✗ could not list deployments to verify teardown"
  leftovers=$((leftovers + 1))
else
  remaining_deploys="$(printf '%s' "$deploy_body" \
    | jq -r --arg s "$suffix" '[.deployments[]? | .apiProxy | select(startswith($s))] | .[]')"
  if [ -n "$remaining_deploys" ]; then
    echo "    ✗ deployments still present:"; printf '%s\n' "$remaining_deploys" | sed 's/^/        /'
    leftovers=$((leftovers + 1))
  else
    echo "    ✓ no deployments with suffix $suffix remain"
  fi
fi

if [ "$leftovers" -gt 0 ]; then
  echo
  echo "ERROR: fixture teardown incomplete in shared org $APIGEE_ORG." >&2
  echo "       Leftovers will be silently adopted by the next run instead of" >&2
  echo "       being created, so the fixtures under test would be stale." >&2
  exit 1
fi

echo "Fixtures removed and verified."
