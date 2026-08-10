#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project owning the Apigee organization
#   APIGEE_ORG      - optional; resolved from GCP_PROJECT_ID when empty
#
# Flags access-control drift in the developer layer (severity 3):
#   - developers that are inactive/blocked while their apps remain attached
#   - apps whose credentials reference API products that no longer exist
#     (dangling references)
#
# Writes developer_status_issues.json and developer_status_status.json.
#
# The developer listing MUST be requested with expand=true. Without it the API
# returns email addresses only -- no status and no developerId -- which makes
# the developer-status half of this check match nothing and report healthy
# forever. See apigee_list_developers for why that list cannot be paginated.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ISSUES_FILE="developer_status_issues.json"
STATUS_FILE="developer_status_status.json"

org_rc=0
resolve_apigee_org || org_rc=$?
if [ "$org_rc" -eq 2 ]; then
  apigee_finish_not_applicable "$ISSUES_FILE" "$STATUS_FILE"
  exit 0
elif [ "$org_rc" -ne 0 ]; then
  apigee_note_failure "Could not determine the Apigee organization for project $GCP_PROJECT_ID"
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Developer-status check could not run: the Apigee organization could not be determined."
  exit 0
fi

echo "Checking developer status and dangling references in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

if ! apps="$(apigee_list_apps)"; then
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Developer-status check could not run: unable to list developer apps."
  exit 0
fi

if ! products="$(apigee_list_api_products)"; then
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Developer-status check could not run: unable to list API products."
  exit 0
fi

if ! developers="$(apigee_list_developers)"; then
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Developer-status check could not run: unable to list developers."
  exit 0
fi

if apigee_developers_truncated "$developers"; then
  apigee_note_failure "Developer list truncated at $APIGEE_PAGE_SIZE records; developer-status findings are incomplete"
fi

jq -n \
  --argjson apps "$apps" \
  --argjson products "$products" \
  --argjson developers "$developers" \
  --arg org "$APIGEE_ORG" '
  ([ $products[] | .name // empty ] | unique) as $existing
  | ([ $apps[] | .developerId // empty ] | unique) as $owning_devs
  |
  ( # --- Dangling product references from app credentials -------------------
    [ $apps[]
      | . as $app
      | (($app.name // "unknown")) as $app_name
      | (($app.credentials // [])[]
          | . as $cred
          | (($cred.consumerKey // "") | .[0:8]) as $key_short
          | (($cred.apiProducts // [])[]
              | (.apiproduct // "") as $pname
              | select($pname != "")
              | select(($existing | index($pname)) == null)
              | {
                  title: "App `\($app_name)` references a non-existent API product `\($pname)`",
                  details: "Developer app `\($app_name)` in org `\($org)` has a consumer key (`\($key_short)...`) attached to API product `\($pname)`, which no longer exists in the organization. This is a dangling access-control reference.",
                  severity: 3,
                  next_steps: "Remove the broken product association from app `\($app_name)` and update the credential to reference a valid API product.",
                  expected: "App credentials should only reference API products that currently exist",
                  actual: "App `\($app_name)` references missing API product `\($pname)`",
                  app: $app_name,
                  product: $pname,
                  issue_type: "dangling_product_ref"
                } ) ) ]
    +
    # --- Developers that own apps but are not active -------------------------
    [ $developers[]
      | . as $dev
      | (($dev.developerId // "")) as $dev_id
      | (($dev.email // $dev.userName // "unknown")) as $email
      | (($dev.status // "")) as $status
      | select($status != "" and $status != "active")
      | select(($owning_devs | index($dev_id)) != null)
      | ([ $apps[] | select((.developerId // "") == $dev_id) ] | length) as $app_count
      | {
          title: "Developer `\($email)` is \($status) while their apps are attached",
          details: "Developer `\($email)` (id `\($dev_id)`) in org `\($org)` has status `\($status)`, but still owns \($app_count) developer app(s). This access-control drift can leave orphaned active entitlements.",
          severity: 3,
          next_steps: "Review developer `\($email)`. Deactivate or revoke the app credentials if the developer should no longer consume the APIs.",
          expected: "Inactive/blocked developers should not have active apps or credentials",
          actual: "Developer `\($email)` is \($status) with \($app_count) app(s) attached",
          developer: $email,
          issue_type: "developer_status_drift"
        } ] )
  | flatten
' > "$ISSUES_FILE"

apigee_write_status "$STATUS_FILE"
echo "Developer status/dangling-reference check complete. Found $(jq 'length' "$ISSUES_FILE") issue(s)."
