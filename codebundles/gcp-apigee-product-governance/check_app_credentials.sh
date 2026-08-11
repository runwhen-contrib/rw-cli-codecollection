#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID           - GCP project owning the Apigee organization
#   APIGEE_ORG               - optional; resolved from GCP_PROJECT_ID when empty
#   DEVELOPER_APPS           - optional; comma-separated app names or 'All'
#   KEY_EXPIRY_WARNING_DAYS  - optional; days before expiry to warn (default 30)
#
# For each developer-app consumer key, checks that the credential is not expired
# or expiring within KEY_EXPIRY_WARNING_DAYS. Expired/expiring keys break
# consumer traffic with 401s.
#
# Writes api_credentials_issues.json and api_credentials_status.json.
#
# expiresAt semantics (Apigee management API): an int64 string of milliseconds
# since epoch. The documented default is `-1`, which means the key NEVER
# expires -- see the keyExpiresIn field: "If not set or left to the default
# value of -1, the API key never expires." Any non-positive value is therefore
# a non-expiring key, not an expired one.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
DEVELOPER_APPS="${DEVELOPER_APPS:-All}"
KEY_EXPIRY_WARNING_DAYS="${KEY_EXPIRY_WARNING_DAYS:-30}"
ISSUES_FILE="api_credentials_issues.json"
STATUS_FILE="api_credentials_status.json"

org_rc=0
resolve_apigee_org || org_rc=$?
if [ "$org_rc" -eq 2 ]; then
  apigee_finish_not_applicable "$ISSUES_FILE" "$STATUS_FILE"
  exit 0
elif [ "$org_rc" -ne 0 ]; then
  apigee_note_failure "Could not determine the Apigee organization for project $GCP_PROJECT_ID"
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Consumer-key expiry check could not run: the Apigee organization could not be determined."
  exit 0
fi

echo "Checking developer app consumer-key expiry in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

if ! all_apps="$(apigee_list_apps)"; then
  echo '[]' > "$ISSUES_FILE"
  apigee_write_status "$STATUS_FILE"
  echo "Consumer-key expiry check could not run: unable to list developer apps."
  exit 0
fi

if [ "$DEVELOPER_APPS" != "All" ] && [ -n "$DEVELOPER_APPS" ]; then
  filter="$(printf '%s' "$DEVELOPER_APPS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -sc .)"
  apps="$(printf '%s' "$all_apps" | jq -c --argjson names "$filter" \
    '[.[] | select(.name as $n | $names | index($n) != null)]')"
else
  apps="$all_apps"
fi

now_ms="$(( $(date -u +%s) * 1000 ))"
warn_ms="$(( now_ms + KEY_EXPIRY_WARNING_DAYS * 86400000 ))"

printf '%s' "$apps" | jq \
  --arg org "$APIGEE_ORG" \
  --argjson now "$now_ms" \
  --argjson warn "$warn_ms" \
  --argjson warn_days "$KEY_EXPIRY_WARNING_DAYS" '
  def days($ms): (($ms / 86400000) | floor);

  # Identify a credential by its ISSUE DATE, never by its consumer key.
  #
  # For products using VerifyAPIKey the consumer key IS the credential, so even
  # a prefix is credential material -- and issue titles propagate furthest, into
  # dashboards and notifications. issuedAt is non-secret, stable for the life of
  # the credential, and enough to find the key in the Apigee console.
  def key_id($cred):
    ((($cred.issuedAt // "") | tostring | (tonumber? // null))) as $i
    | if $i == null then "" else " issued \(($i / 1000 | floor) | todate | .[0:10])" end;

  [ .[]
    | . as $app
    | (($app.name // "unknown")) as $app_name
    | (($app.developerId // "unknown")) as $dev_id
    | (($app.credentials // [])[]
        | . as $cred
        | (key_id($cred)) as $key_id
        | (($cred.expiresAt // "") | tostring | gsub("\\s"; "")) as $raw
        | if ($raw == "" or $raw == "null") then empty
          else
            # tonumber? yields *empty* (not null) on a non-numeric string, which
            # would drop the credential silently; // null turns that into a
            # value the branch below can report on.
            (($raw | tonumber?) // null) as $exp
            | if $exp == null then
                # Neither a number nor absent: the expiry is unreadable. Report
                # it rather than skipping, so an unparsed field is never
                # indistinguishable from a healthy key.
                [{
                  title: "Consumer key\($key_id) on app `\($app_name)` has an unreadable expiry",
                  details: "The credential on developer app `\($app_name)` (developer `\($dev_id)`) in org `\($org)` reports expiresAt=`\($raw)`, which is not an epoch-milliseconds value. Its expiry state could not be evaluated.",
                  severity: 4,
                  next_steps: "Inspect the credential on app `\($app_name)` via the Apigee management API and confirm the expiresAt field.",
                  expected: "Consumer key expiry should be readable as epoch milliseconds",
                  actual: "Consumer key on app `\($app_name)` has expiresAt=`\($raw)`",
                  app: $app_name,
                  issue_type: "credential_expiry_unreadable"
                }]
              elif $exp <= 0 then
                # -1 (documented default) and 0 both mean "never expires".
                []
              elif $exp <= $now then
                [{
                  title: "Consumer key\($key_id) on app `\($app_name)` is EXPIRED",
                  details: "The consumer key on developer app `\($app_name)` (developer `\($dev_id)`) in org `\($org)` expired approximately \(days($now - $exp)) day(s) ago. Consumers will receive 401s.",
                  severity: 3,
                  next_steps: "Generate a new consumer key/secret for app `\($app_name)` and rotate the credential in the consuming system.",
                  expected: "Consumer keys should not be expired; they silently break consumer traffic",
                  actual: "Consumer key on app `\($app_name)` expired \(days($now - $exp)) day(s) ago",
                  app: $app_name,
                  issue_type: "credential_expired"
                }]
              elif $exp <= $warn then
                [{
                  title: "Consumer key\($key_id) on app `\($app_name)` expires within \($warn_days) days",
                  details: "The consumer key on developer app `\($app_name)` (developer `\($dev_id)`) in org `\($org)` expires in approximately \(days($exp - $now)) day(s), within the \($warn_days)-day warning window. It should be rotated before expiry to avoid 401s.",
                  severity: 3,
                  next_steps: "Rotate the consumer key/secret for app `\($app_name)` before it expires. Consider alerting on key age.",
                  expected: "Consumer keys should not expire within the warning window",
                  actual: "Consumer key on app `\($app_name)` expires in \(days($exp - $now)) day(s)",
                  app: $app_name,
                  issue_type: "credential_expiring"
                }]
              else [] end
          end )
  ] | flatten
' > "$ISSUES_FILE"

apigee_write_status "$STATUS_FILE"
echo "Consumer-key expiry check complete. Evaluated $(printf '%s' "$apps" | jq 'length') app(s), found $(jq 'length' "$ISSUES_FILE") issue(s)."
