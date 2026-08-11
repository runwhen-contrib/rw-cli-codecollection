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

: "${APIGEE_ORG:=${TF_VAR_org_id:-}}"
: "${APIGEE_ORG:?Must set APIGEE_ORG (or TF_VAR_org_id)}"
# The URLs below already carry the "organizations/" segment; the sibling bundles
# name the same org in the prefixed form, so accept both spellings.
APIGEE_ORG="${APIGEE_ORG#organizations/}"
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

# dangling-app must hold a credential referencing a product that does not exist.
#
# The obvious construction -- create a transient product, attach it, delete it --
# does NOT work. Apigee enforces referential integrity in both directions and
# refuses the delete:
#
#   HTTP 400: Unable to delete ApiProduct as there are one or more apps
#             associated with it.
#
# So attach the non-existent product directly instead. UpdateDeveloperAppKey is
# the documented way to associate a product with a key; whether it validates the
# product's existence is not documented, so this is an attempt, not a
# guarantee. The result is verified below either way -- it is never assumed.
echo "  Attempting the dangling reference on $suffix-dangling-app"
dangling_key="$(curl -fsS "${AUTH[@]}" "$ORG_URL/developers/$email/apps/$suffix-dangling-app" \
  | jq -r '[.credentials[]?.consumerKey] | .[0] // empty')"
[ -n "$dangling_key" ] || { echo "ERROR: $suffix-dangling-app has no consumer key to attach a product to." >&2; exit 1; }

dangling_resp="$(curl -sS -o /tmp/apigee_dangle.$$ -w '%{http_code}' -X POST "${AUTH[@]}" \
  "$ORG_URL/developers/$email/apps/$suffix-dangling-app/keys/$dangling_key" \
  -d "$(jq -nc --arg p "$suffix-missing-product" '{apiProducts:[$p]}')" 2>/dev/null || echo "000")"
case "$dangling_resp" in
  2*) echo "    attach accepted (HTTP $dangling_resp)" ;;
  *)  echo "    attach rejected (HTTP $dangling_resp): $(head -c 200 "/tmp/apigee_dangle.$$" 2>/dev/null)" ;;
esac
rm -f "/tmp/apigee_dangle.$$"

# -----------------------------------------------------------------------------
# Ground truth. Every assertion below states the property a check depends on;
# if one fails the fixture is not broken the way it claims and the corresponding
# check would pass for the wrong reason.
# -----------------------------------------------------------------------------
# --- Developer status drift ---------------------------------------------------
# The developer owns apps that stay approved; setting the developer inactive is
# what the developer-status check looks for. Without this step there is no live
# known-positive for developer_status_drift.
#
# setDeveloperStatus takes the state in the `action` query parameter and wants
# Content-Type: application/octet-stream, not JSON. It returns 204.
echo "  Setting developer $email inactive (known-positive for developer_status_drift)"
dev_status_resp="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/octet-stream" \
  "$ORG_URL/developers/$email?action=inactive" 2>/dev/null || echo "000")"
case "$dev_status_resp" in
  2*) ;;
  *)  echo "ERROR: could not set developer $email inactive (HTTP $dev_status_resp)." >&2
      echo "       developer_status_drift would have no live known-positive." >&2
      exit 1 ;;
esac

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
# Fetch separately: a bare `curl | jq` inside the gt call would abort the script
# under `set -e -o pipefail` before gt could report expected-vs-actual.
dev_body="$(curl -fsS "${AUTH[@]}" "$ORG_URL/developers/$email" 2>/dev/null || echo '{}')"
gt "developer $email is inactive" \
  "$(printf '%s' "$dev_body" | jq -r '.status // "unreadable"')" "inactive"
# The dangling reference is the one fixture whose reachability through the
# public API is unproven -- see the attach attempt above. Report its absence
# loudly, but do not fail the whole provisioning run over it: that would block
# the live tier entirely and cost live coverage of the other four checks, which
# is a worse outcome than one known-positive being offline-only.
# Set REQUIRE_DANGLING_FIXTURE=1 to make its absence fatal.
dangling_present="$(printf '%s' "$apps_json" | jq -r \
  --arg n "$suffix-dangling-app" --arg p "$suffix-missing-product" \
  '[.app[]?|select(.name==$n)|.credentials[]?|.apiProducts[]?|select(.apiproduct==$p)]|length')"
if [ "$dangling_present" = "1" ]; then
  echo "    ✓ $suffix-dangling-app references the non-existent product"
  DANGLING_FIXTURE_STATE="present"
else
  DANGLING_FIXTURE_STATE="unreachable"
  if [ "${REQUIRE_DANGLING_FIXTURE:-0}" = "1" ]; then
    echo "    ✗ $suffix-dangling-app does not reference a non-existent product"
    gt_failures=$((gt_failures + 1))
  else
    echo "    ! $suffix-dangling-app does NOT reference a non-existent product."
    echo "      Apigee appears to validate the product on attach, and it refuses to"
    echo "      delete a product any app references, so this state may not be"
    echo "      reachable through the public API at all."
    echo "      CONSEQUENCE: dangling_product_ref has OFFLINE COVERAGE ONLY. The live"
    echo "      run does not exercise it. Re-run with REQUIRE_DANGLING_FIXTURE=1 to"
    echo "      treat this as fatal."
  fi
fi

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

echo
echo "Fixtures created and verified. Known-positive coverage for the live run:"
echo "  auto_approval           present  ($suffix-auto-approve)"
echo "  missing_quota           present  ($suffix-auto-approve)"
echo "  orphaned_product        present  ($suffix-orphaned)"
echo "  app_no_keys             present  ($suffix-empty-app)"
echo "  credential_expiring     present  ($suffix-expiring-app)"
echo "  developer_status_drift  present  ($email set inactive)"
if [ "$DANGLING_FIXTURE_STATE" = "present" ]; then
  echo "  dangling_product_ref    present  ($suffix-dangling-app)"
else
  echo "  dangling_product_ref    ABSENT   -- offline coverage only, see the note above"
fi
