#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# delete_entitlement_fixtures.sh
#
# Removes the Apigee entitlement fixtures created by
# create_entitlement_fixtures.sh from the shared test organization, then VERIFIES
# that nothing carrying the fixture suffix survives. Leftovers in a shared org
# are not harmless: an abandoned product shows up as an orphaned entitlement in
# every later run.
#
# Exits non-zero if anything with the suffix is still present afterwards.
# -----------------------------------------------------------------------------
set -uo pipefail

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required." >&2; exit 1; }
done

BASE="https://apigee.googleapis.com/v1"
ORG_URL="$BASE/organizations/$APIGEE_ORG"
TOKEN="${APIGEE_TOKEN:-$(gcloud auth print-access-token)}"
[ -n "$TOKEN" ] || { echo "ERROR: could not obtain an access token." >&2; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN")

suffix="${FIXTURE_SUFFIX:-test001}"
email="governance-$suffix@example.com"

echo "Removing Apigee governance fixtures (suffix: $suffix) from org: $APIGEE_ORG"

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

for app in healthy-app expiring-app empty-app dangling-app auto-app; do
  api_delete "$ORG_URL/developers/$email/apps/$suffix-$app"
done

api_delete "$ORG_URL/developers/$email"

for prod in healthy-api auto-approve orphaned transient; do
  api_delete "$ORG_URL/apiproducts/$suffix-$prod"
done

# --- Verify against the provider, not against local state --------------------
echo "Verifying teardown"
leftovers=0

# The fetch and the filter are kept separate on purpose. Piping curl into jq and
# swallowing errors would turn "could not query the org" into an empty result,
# i.e. into "nothing left over" -- the exact blind pass this step exists to
# prevent.
if ! products_body="$(curl -fsS "${AUTH[@]}" "$ORG_URL/apiproducts?count=1000")"; then
  echo "    ✗ could not list API products to verify teardown"
  leftovers=$((leftovers + 1))
else
  remaining_products="$(printf '%s' "$products_body" \
    | jq -r --arg s "$suffix" '[.apiProduct[]? | (if type == "string" then . else .name end) | select(startswith($s))] | .[]')"
  if [ -n "$remaining_products" ]; then
    # Indent with sed rather than an unquoted expansion: Apigee product names
    # may contain spaces, which word splitting would report as two leftovers.
    echo "    ✗ API products still present:"; printf '%s\n' "$remaining_products" | sed 's/^/        /'
    leftovers=$((leftovers + 1))
  else
    echo "    ✓ no API products with suffix $suffix remain"
  fi
fi

if ! apps_body="$(curl -fsS "${AUTH[@]}" "$ORG_URL/apps?expand=true&pageSize=1000")"; then
  echo "    ✗ could not list developer apps to verify teardown"
  leftovers=$((leftovers + 1))
else
  remaining_apps="$(printf '%s' "$apps_body" \
    | jq -r --arg s "$suffix" '[.app[]? | .name | select(startswith($s))] | .[]')"
  if [ -n "$remaining_apps" ]; then
    echo "    ✗ developer apps still present:"; printf '%s\n' "$remaining_apps" | sed 's/^/        /'
    leftovers=$((leftovers + 1))
  else
    echo "    ✓ no developer apps with suffix $suffix remain"
  fi
fi

if curl -fsS "${AUTH[@]}" "$ORG_URL/developers/$email" >/dev/null 2>&1; then
  echo "    ✗ developer $email still present"
  leftovers=$((leftovers + 1))
else
  echo "    ✓ developer $email removed"
fi

if [ "$leftovers" -gt 0 ]; then
  echo
  echo "ERROR: fixture teardown incomplete in shared org $APIGEE_ORG." >&2
  echo "       Leftovers will be reported as orphaned entitlements by later runs." >&2
  exit 1
fi

echo "Fixtures removed and verified."
