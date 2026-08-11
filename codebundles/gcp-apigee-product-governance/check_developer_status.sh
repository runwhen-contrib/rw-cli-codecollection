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

# Truncation is reported as a finding, not as an access failure. The developers
# that WERE returned are analysed normally and their findings are real; the list
# is simply incomplete. Marking the whole check unreadable would discard those
# real findings, so the incompleteness is raised as its own issue instead.
truncated="false"
if apigee_developers_truncated "$developers"; then
  truncated="true"
fi

jq -n \
  --argjson apps "$apps" \
  --argjson products "$products" \
  --argjson developers "$developers" \
  --arg org "$APIGEE_ORG" --arg project "$GCP_PROJECT_ID" "$APIGEE_JQ_HELPERS"'
  ([ $products[] | .name // empty ] | unique) as $existing
  | ([ $apps[] | .developerId // empty ] | unique) as $owning_devs
  # One record per broken association, then grouped: the SLX is project-scoped,
  # so several apps referencing missing products are occurrences of one issue.
  | ([ $apps[]
      | . as $app
      | (($app.name // "unknown")) as $app_name
      | (($app.credentials // [])[]
          | . as $cred
          # Identify the credential by issue date, never by its consumer key --
          # for VerifyAPIKey products the key IS the credential. The product
          # name already disambiguates which association is broken.
          | (((($cred.issuedAt // "") | tostring | (tonumber? // null))) as $i
             | if $i == null then "a credential"
               else "the credential issued \(($i / 1000 | floor) | todate | .[0:10])" end) as $key_id
          | (($cred.apiProducts // [])[]
              | (.apiproduct // "") as $pname
              | select($pname != "")
              | select(($existing | index($pname)) == null)
              | {app: $app_name, product: $pname,
                 desc: "`\($app_name)` -- \($key_id) references missing product `\($pname)`"} ) ) ]) as $dangling
  | ([ $developers[]
      | . as $dev
      | (($dev.developerId // "")) as $dev_id
      | (($dev.email // $dev.userName // "unknown")) as $email
      | (($dev.status // "")) as $status
      | select($status != "" and $status != "active")
      | select(($owning_devs | index($dev_id)) != null)
      | ([ $apps[] | select((.developerId // "") == $dev_id) ] | length) as $app_count
      | {developer: $email, status: $status, app_count: $app_count,
         desc: "`\($email)` -- status `\($status)`, \($app_count) app(s) attached"} ]) as $drift
  |
  ( (if ($dangling | length) > 0 then [{
        title: "Developer apps reference non-existent API products in project `\($project)`",
        details: "\($dangling | length) credential association(s) in org `\($org)` point at API products that no longer exist. These are dangling access-control references.\n\nAffected apps:\n\(fmt_list($dangling | map(.desc)))",
        severity: 3,
        next_steps: "Remove the broken product associations from the affected apps and update each credential to reference a valid API product.",
        expected: "App credentials should only reference API products that currently exist",
        actual: "\($dangling | length) dangling reference(s) across app(s): \(fmt_inline($dangling | map(.app) | unique))",
        affected_count: ($dangling | length),
        apps: ($dangling | map(.app) | unique),
        products: ($dangling | map(.product) | unique),
        issue_type: "dangling_product_ref"
      }] else [] end)
    +
    (if ($drift | length) > 0 then [{
        title: "Inactive developers still own apps in project `\($project)`",
        details: "\($drift | length) developer(s) in org `\($org)` are not active but still own developer apps. This access-control drift can leave orphaned active entitlements.\n\nAffected developers:\n\(fmt_list($drift | map(.desc)))",
        severity: 3,
        next_steps: "Review each developer. Deactivate or revoke the app credentials for any who should no longer consume the APIs.",
        expected: "Inactive/blocked developers should not have active apps or credentials",
        actual: "\($drift | length) non-active developer(s) still own apps: \(fmt_inline($drift | map(.developer)))",
        affected_count: ($drift | length),
        developers: ($drift | map(.developer)),
        issue_type: "developer_status_drift"
      }] else [] end)
  )
' > "$ISSUES_FILE"

# developers.list rejects `expand` alongside `count`/`startKey`, so the expanded
# list cannot be paginated and stops at APIGEE_PAGE_SIZE. Anything beyond that
# was not evaluated, so say so rather than letting a partial pass read as a
# clean one.
if [ "$truncated" = "true" ]; then
  jq --argjson extra "$(apigee_issue \
    "Developer list is truncated at $APIGEE_PAGE_SIZE records in project \`$GCP_PROJECT_ID\`" \
    "The Apigee developers.list endpoint returned the maximum of $APIGEE_PAGE_SIZE expanded developers for org \`$APIGEE_ORG\`. The API rejects pagination parameters when expand=true, so developers beyond this cap were not evaluated and the developer-status findings below are incomplete. Dangling-reference findings are unaffected -- they are derived from the app list, which does paginate." \
    3 \
    "Scope the analysis with DEVELOPER_APPS, or evaluate developer status through a paginated unexpanded listing plus per-developer lookups." \
    "The full developer list should be evaluable for org \`$APIGEE_ORG\`" \
    "Only the first $APIGEE_PAGE_SIZE developers in org \`$APIGEE_ORG\` were evaluated" \
    "$(jq -cn --arg org "$APIGEE_ORG" --arg project "$GCP_PROJECT_ID" '{org:$org, issue_type:"developer_list_truncated"}')")" \
    '. + [$extra]' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
fi

apigee_write_status "$STATUS_FILE"
echo "Developer status/dangling-reference check complete. Found $(jq 'length' "$ISSUES_FILE") issue(s)."
