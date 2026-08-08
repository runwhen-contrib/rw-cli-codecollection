#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# delete_entitlement_fixtures.sh
#
# Removes the Apigee entitlement fixtures created by
# create_entitlement_fixtures.sh from the shared test organization.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

BASE="https://apigee.googleapis.com/v1"
TOKEN="${APIGEE_TOKEN:-$(gcloud auth print-access-token)}"
AUTH=(-H "Authorization: Bearer $TOKEN")

suffix="${FIXTURE_SUFFIX:-test001}"
email="governance-$suffix@example.com"

echo "Removing Apigee governance fixtures from org: $APIGEE_ORG"

for app in "$suffix-healthy-app" "$suffix-expiring-app" "$suffix-empty-app" "$suffix-dangling-app" "$suffix-auto-app"; do
  curl -fsS -X DELETE "${AUTH[@]}" \
    "$BASE/organizations/$APIGEE_ORG/developers/$email/apps/$app" >/dev/null 2>&1 || true
done

curl -fsS -X DELETE "${AUTH[@]}" \
  "$BASE/organizations/$APIGEE_ORG/developers/$email" >/dev/null 2>&1 || true

for prod in "$suffix-healthy-api" "$suffix-auto-approve" "$suffix-orphaned"; do
  curl -fsS -X DELETE "${AUTH[@]}" \
    "$BASE/organizations/$APIGEE_ORG/apiproducts/$prod" >/dev/null 2>&1 || true
done

echo "Fixtures removed."
