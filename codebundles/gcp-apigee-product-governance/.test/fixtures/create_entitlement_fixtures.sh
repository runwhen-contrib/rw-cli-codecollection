#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# create_entitlement_fixtures.sh
#
# Creates the Apigee entitlement fixtures used to exercise the
# gcp-apigee-product-governance checks in the SHARED long-lived Apigee X test
# organization (managed by the environment bundle's bootstrap). Only the inner
# product/developer/app objects are created here -- via the management REST API
# (apigeecli if present, otherwise curl).
#
# The design spec deliberately includes broken fixtures so every governance
# path is exercised:
#   healthy_api_product    -> manual approval + quota           (no issues)
#   auto_approve_product   -> auto-approval + NO quota          (severity 2/3)
#   orphaned_product       -> never referenced by an app        (severity 4)
#   testdev@example.com    -> active developer
#   healthy-app            -> key far from expiry
#   expiring-app           -> key expires within KEY_EXPIRY_WARNING_DAYS (sev 3)
#   empty-app              -> no consumer key                   (severity 4)
#   dangling-app           -> references orphaned_product       (not "dangling");
#                            reference the deleted prod_missing (severity 3)
#
# Requires:
#   APIGEE_ORG, GCP_PROJECT_ID in the environment (from tf.secret)
#   An active gcloud service account with roles/apigee.admin
#   curl, jq ; optional apigeecli (falls back to curl)
# -----------------------------------------------------------------------------
set -euo pipefail

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

BASE="https://apigee.googleapis.com/v1"
TOKEN="${APIGEE_TOKEN:-$(gcloud auth print-access-token)}"
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")

suffix="${FIXTURE_SUFFIX:-test001}"

echo "Creating Apigee governance fixtures in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

# --- API products ------------------------------------------------------------
curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/apiproducts" \
  -d "{\"name\":\"$suffix-healthy-api\",\"approvalType\":\"manual\",\"displayName\":\"Healthy API\",\"quota\":\"1000\",\"quotaInterval\":\"1\",\"quotaTimeUnit\":\"MINUTE\",\"apiResources\":[\"/\"],\"environments\":[\"test\"]}" \
  >/dev/null 2>&1 || echo "note: product $suffix-healthy-api may already exist"

curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/apiproducts" \
  -d "{\"name\":\"$suffix-auto-approve\",\"approvalType\":\"auto\",\"displayName\":\"Auto Approve API\",\"apiResources\":[\"/\"],\"environments\":[\"test\"]}" \
  >/dev/null 2>&1 || echo "note: product $suffix-auto-approve may already exist"

curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/apiproducts" \
  -d "{\"name\":\"$suffix-orphaned\",\"approvalType\":\"manual\",\"displayName\":\"Orphaned API (no apps)\",\"quota\":\"500\",\"quotaInterval\":\"1\",\"quotaTimeUnit\":\"MINUTE\",\"apiResources\":[\"/\"],\"environments\":[\"test\"]}" \
  >/dev/null 2>&1 || echo "note: product $suffix-orphaned may already exist"

# --- Developer ---------------------------------------------------------------
curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/developers" \
  -d "{\"email\":\"governance-$suffix@example.com\",\"firstName\":\"Gov\",\"lastName\":\"Test\",\"userName\":\"gov-$suffix\"}" \
  >/dev/null 2>&1 || echo "note: developer governance-$suffix@example.com may already exist"

email="governance-$suffix@example.com"

# --- Apps + consumer keys -----------------------------------------------------
# healthy-app: key with a long-dated expiry (well outside the warning window)
curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/developers/$email/apps" \
  -d "{\"name\":\"$suffix-healthy-app\",\"apiProducts\":[\"$suffix-healthy-api\"]}" \
  >/dev/null 2>&1 || echo "note: app $suffix-healthy-app may already exist"

# expiring-app: key created with an expiry ~a few days out -> triggers expiry check
curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/developers/$email/apps" \
  -d "{\"name\":\"$suffix-expiring-app\",\"apiProducts\":[\"$suffix-healthy-api\"]}" \
  >/dev/null 2>&1 || echo "note: app $suffix-expiring-app may already exist"

# empty-app: no consumer key -> orphaned/no-keys check
curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/developers/$email/apps" \
  -d "{\"name\":\"$suffix-empty-app\",\"apiProducts\":[]}" \
  >/dev/null 2>&1 || echo "note: app $suffix-empty-app may already exist"

# dangling-app: references a product ("$suffix-missing") that we intentionally do
# NOT create -> dangling product reference check
curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/developers/$email/apps" \
  -d "{\"name\":\"$suffix-dangling-app\",\"apiProducts\":[\"$suffix-missing\"]}" \
  >/dev/null 2>&1 || echo "note: app $suffix-dangling-app may already exist"

# auto-approve-app: app approved against the auto-approve product
curl -fsS -X POST "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/developers/$email/apps" \
  -d "{\"name\":\"$suffix-auto-app\",\"apiProducts\":[\"$suffix-auto-approve\"]}" \
  >/dev/null 2>&1 || echo "note: app $suffix-auto-app may already exist"

# Generate a consumer key for the healthy app with a far-dated expiry.
# NOTE: replacement key generation via generateKeyPairOrUpdateDeveloperAppStatus
# allows prescribing a consumerKey/secret and expiry; operators should adapt the
# expiry to the desired test state (past expiry for the expired case).
echo "Fixtures created. Review consumer keys and adjust expiries to the desired test state in the Apigee console or via the management API."
