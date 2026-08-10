#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# create_entitlement_fixtures.sh
#
# Creates the Apigee entitlement fixtures used to exercise the
# gcp-apigee-product-governance checks in the SHARED long-lived Apigee X test
# organization. Only the inner product/developer/app objects are created here --
# via the management REST API -- because Terraform has no first-class provider
# for them.
#
# Fixtures, and the check each one is the known-positive for:
#   <suffix>-healthy-api     manual approval + quota          -> no issue
#   <suffix>-auto-approve    auto-approval + NO quota         -> sev 2 and 3
#   <suffix>-orphaned        never referenced by an app       -> sev 4
#   governance-<suffix>@...  developer that owns the apps
#   <suffix>-healthy-app     key far from expiry              -> no issue
#   <suffix>-expiring-app    key expiring inside the window   -> sev 3
#   <suffix>-empty-app       app with NO consumer key         -> sev 4
#   <suffix>-dangling-app    references a product that does not exist -> sev 3
#   <suffix>-auto-app        consumes the auto-approve product
#
# This script FAILS (non-zero) if any object cannot be created or does not end
# up in the state it claims. A "broken" fixture that quietly provisions healthy
# removes the only thing under test, so every creation is verified by reading
# the object back.
#
# Requires:
#   APIGEE_ORG, GCP_PROJECT_ID in the environment (from tf.secret)
#   APIGEE_TEST_ENV      - name of an existing Apigee environment (default: test)
#   An active gcloud service account with roles/apigee.admin
#   curl, jq
# -----------------------------------------------------------------------------
set -euo pipefail

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
APIGEE_TEST_ENV="${APIGEE_TEST_ENV:-test}"

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: $tool is required." >&2; exit 1; }
done

BASE="https://apigee.googleapis.com/v1"
ORG_URL="$BASE/organizations/$APIGEE_ORG"
TOKEN="${APIGEE_TOKEN:-$(gcloud auth print-access-token)}"
[ -n "$TOKEN" ] || { echo "ERROR: could not obtain an access token." >&2; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

suffix="${FIXTURE_SUFFIX:-test001}"
email="governance-$suffix@example.com"

echo "Creating Apigee governance fixtures in org: $APIGEE_ORG (project: $GCP_PROJECT_ID, env: $APIGEE_TEST_ENV, suffix: $suffix)"

# --- Preconditions ------------------------------------------------------------
if ! curl -fsS "${AUTH[@]}" "$ORG_URL" >/dev/null; then
  echo "ERROR: cannot read organization $APIGEE_ORG. Check credentials and roles/apigee.admin." >&2
  exit 1
fi
if ! curl -fsS "${AUTH[@]}" "$ORG_URL/environments/$APIGEE_TEST_ENV" >/dev/null; then
  echo "ERROR: environment '$APIGEE_TEST_ENV' does not exist in org $APIGEE_ORG." >&2
  echo "       Create it, or set APIGEE_TEST_ENV to an existing environment." >&2
  exit 1
fi

# api_post <url> <json>: create, tolerating "already exists" (409) but nothing
# else. A 403 or 400 must not be mistaken for idempotency.
api_post() {
  local url="$1" body="$2" code
  code="$(curl -sS -o /tmp/apigee_fixture_resp.$$ -w '%{http_code}' \
    -X POST "${AUTH[@]}" "$url" -d "$body")"
  case "$code" in
    2*) return 0 ;;
    409) echo "    (already exists)"; return 0 ;;
    *)
      echo "ERROR: POST $url returned HTTP $code" >&2
      head -c 500 "/tmp/apigee_fixture_resp.$$" >&2; echo >&2
      rm -f "/tmp/apigee_fixture_resp.$$"
      return 1 ;;
  esac
}

# --- API products -------------------------------------------------------------
echo "  API products"
api_post "$ORG_URL/apiproducts" "$(jq -nc --arg n "$suffix-healthy-api" --arg e "$APIGEE_TEST_ENV" \
  '{name:$n, displayName:"Healthy API", approvalType:"manual", quota:"1000", quotaInterval:"1", quotaTimeUnit:"minute", apiResources:["/"], environments:[$e]}')"
api_post "$ORG_URL/apiproducts" "$(jq -nc --arg n "$suffix-auto-approve" --arg e "$APIGEE_TEST_ENV" \
  '{name:$n, displayName:"Auto Approve API", approvalType:"auto", apiResources:["/"], environments:[$e]}')"
api_post "$ORG_URL/apiproducts" "$(jq -nc --arg n "$suffix-orphaned" --arg e "$APIGEE_TEST_ENV" \
  '{name:$n, displayName:"Orphaned API (no apps)", approvalType:"manual", quota:"500", quotaInterval:"1", quotaTimeUnit:"minute", apiResources:["/"], environments:[$e]}')"

# --- Developer ----------------------------------------------------------------
echo "  Developer"
api_post "$ORG_URL/developers" "$(jq -nc --arg e "$email" --arg u "gov-$suffix" \
  '{email:$e, firstName:"Gov", lastName:"Test", userName:$u}')"

# --- Apps ---------------------------------------------------------------------
# Apigee auto-generates a consumer key when a developer app is created, and
# keyExpiresIn (milliseconds, -1 = never) is the only way to set its expiry at
# creation time.
echo "  Developer apps"
ten_days_ms=$((10 * 24 * 60 * 60 * 1000))
far_ms=$((900 * 24 * 60 * 60 * 1000))

api_post "$ORG_URL/developers/$email/apps" "$(jq -nc --arg n "$suffix-healthy-app" --arg p "$suffix-healthy-api" --argjson k "$far_ms" \
  '{name:$n, apiProducts:[$p], keyExpiresIn:($k|tostring)}')"
api_post "$ORG_URL/developers/$email/apps" "$(jq -nc --arg n "$suffix-expiring-app" --arg p "$suffix-healthy-api" --argjson k "$ten_days_ms" \
  '{name:$n, apiProducts:[$p], keyExpiresIn:($k|tostring)}')"
api_post "$ORG_URL/developers/$email/apps" "$(jq -nc --arg n "$suffix-empty-app" \
  '{name:$n, apiProducts:[]}')"
api_post "$ORG_URL/developers/$email/apps" "$(jq -nc --arg n "$suffix-dangling-app" --arg p "$suffix-healthy-api" \
  '{name:$n, apiProducts:[$p]}')"
api_post "$ORG_URL/developers/$email/apps" "$(jq -nc --arg n "$suffix-auto-app" --arg p "$suffix-auto-approve" \
  '{name:$n, apiProducts:[$p]}')"

# empty-app must have NO credential. Apigee generates one on creation, so it has
# to be deleted explicitly -- otherwise the app_no_keys check has no fixture.
echo "  Removing the auto-generated key from $suffix-empty-app"
empty_keys="$(curl -fsS "${AUTH[@]}" "$ORG_URL/developers/$email/apps/$suffix-empty-app" \
  | jq -r '[.credentials[]?.consumerKey] | .[]')"
for key in $empty_keys; do
  curl -fsS -X DELETE "${AUTH[@]}" \
    "$ORG_URL/developers/$email/apps/$suffix-empty-app/keys/$key" >/dev/null
done

# dangling-app must reference a product that does not exist. Apigee validates
# the product list at app-creation time, so the app is created against a real
# product which is then deleted, leaving the credential's reference dangling.
echo "  Creating the dangling reference via $suffix-transient"
api_post "$ORG_URL/apiproducts" "$(jq -nc --arg n "$suffix-transient" --arg e "$APIGEE_TEST_ENV" \
  '{name:$n, displayName:"Transient (deleted to create a dangling ref)", approvalType:"manual", quota:"10", quotaInterval:"1", quotaTimeUnit:"minute", apiResources:["/"], environments:[$e]}')"
dangling_key="$(curl -fsS "${AUTH[@]}" "$ORG_URL/developers/$email/apps/$suffix-dangling-app" \
  | jq -r '[.credentials[]?.consumerKey] | .[0] // empty')"
[ -n "$dangling_key" ] || { echo "ERROR: $suffix-dangling-app has no consumer key to attach a product to." >&2; exit 1; }
curl -fsS -X POST "${AUTH[@]}" \
  "$ORG_URL/developers/$email/apps/$suffix-dangling-app/keys/$dangling_key" \
  -d "$(jq -nc --arg p "$suffix-transient" '{apiProducts:[$p]}')" >/dev/null
curl -fsS -X DELETE "${AUTH[@]}" "$ORG_URL/apiproducts/$suffix-transient" >/dev/null

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

products_json="$(curl -fsS "${AUTH[@]}" "$ORG_URL/apiproducts?expand=true&count=1000")"
apps_json="$(curl -fsS "${AUTH[@]}" "$ORG_URL/apps?expand=true&includeCred=true&status=approved&pageSize=1000")"
now_ms=$(( $(date -u +%s) * 1000 ))

gt "$suffix-auto-approve uses auto-approval" \
  "$(printf '%s' "$products_json" | jq -r --arg n "$suffix-auto-approve" '.apiProduct[]|select(.name==$n)|.approvalType')" "auto"
gt "$suffix-auto-approve has no quota" \
  "$(printf '%s' "$products_json" | jq -r --arg n "$suffix-auto-approve" '.apiProduct[]|select(.name==$n)|(.quota // "unset")')" "unset"
gt "$suffix-healthy-api has a quota" \
  "$(printf '%s' "$products_json" | jq -r --arg n "$suffix-healthy-api" '.apiProduct[]|select(.name==$n)|.quota')" "1000"
gt "$suffix-orphaned is referenced by no app" \
  "$(printf '%s' "$apps_json" | jq -r --arg n "$suffix-orphaned" '[.app[]?|.credentials[]?|.apiProducts[]?|select(.apiproduct==$n)]|length')" "0"
gt "$suffix-empty-app has no consumer key" \
  "$(printf '%s' "$apps_json" | jq -r --arg n "$suffix-empty-app" '[.app[]?|select(.name==$n)|.credentials[]?]|length')" "0"
gt "$suffix-dangling-app references the deleted product" \
  "$(printf '%s' "$apps_json" | jq -r --arg n "$suffix-dangling-app" --arg p "$suffix-transient" '[.app[]?|select(.name==$n)|.credentials[]?|.apiProducts[]?|select(.apiproduct==$p)]|length')" "1"
gt "$suffix-transient no longer exists" \
  "$(printf '%s' "$products_json" | jq -r --arg n "$suffix-transient" '[.apiProduct[]?|select(.name==$n)]|length')" "0"

expiring_ms="$(printf '%s' "$apps_json" | jq -r --arg n "$suffix-expiring-app" \
  '[.app[]?|select(.name==$n)|.credentials[]?|.expiresAt]|.[0] // "missing"')"
if [ "$expiring_ms" != "missing" ] && [ "$expiring_ms" -gt "$now_ms" ] 2>/dev/null \
   && [ "$expiring_ms" -lt "$(( now_ms + 30 * 86400000 ))" ]; then
  echo "    ✓ $suffix-expiring-app key expires inside the 30-day window"
else
  echo "    ✗ $suffix-expiring-app key expires inside the 30-day window (expiresAt=$expiring_ms, now=$now_ms)"
  gt_failures=$((gt_failures + 1))
fi

healthy_ms="$(printf '%s' "$apps_json" | jq -r --arg n "$suffix-healthy-app" \
  '[.app[]?|select(.name==$n)|.credentials[]?|.expiresAt]|.[0] // "missing"')"
if [ "$healthy_ms" != "missing" ] && [ "$healthy_ms" -gt "$(( now_ms + 30 * 86400000 ))" ] 2>/dev/null; then
  echo "    ✓ $suffix-healthy-app key expires well outside the window"
else
  echo "    ✗ $suffix-healthy-app key expires well outside the window (expiresAt=$healthy_ms)"
  gt_failures=$((gt_failures + 1))
fi

if [ "$gt_failures" -gt 0 ]; then
  echo
  echo "ERROR: $gt_failures fixture(s) are not in the state they claim." >&2
  echo "       Running the checks against them would prove nothing. Fix or re-create the fixtures." >&2
  exit 1
fi

echo "Fixtures created and verified."
