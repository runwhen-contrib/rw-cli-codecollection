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
  --arg org "$APIGEE_ORG" --arg project "$GCP_PROJECT_ID" \
  --argjson now "$now_ms" \
  --argjson warn "$warn_ms" \
  --argjson warn_days "$KEY_EXPIRY_WARNING_DAYS" "$APIGEE_JQ_HELPERS"'
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

  # Flatten to one record per credential, classified, then group by class. The
  # SLX is project-scoped, so each class is one issue listing every affected
  # credential rather than one issue per credential.
  [ .[]
    | . as $app
    | (($app.name // "unknown")) as $app_name
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
                {class: "unreadable", app: $app_name,
                 desc: "`\($app_name)` -- key\($key_id), expiresAt=`\($raw)`"}
              elif $exp <= 0 then empty          # -1 and 0 both mean never expires
              elif $exp <= $now then
                {class: "expired", app: $app_name, days: days($now - $exp),
                 desc: "`\($app_name)` -- key\($key_id), expired \(days($now - $exp)) day(s) ago"}
              elif $exp <= $warn then
                {class: "expiring", app: $app_name, days: days($exp - $now),
                 desc: "`\($app_name)` -- key\($key_id), expires in \(days($exp - $now)) day(s)"}
              else empty end
          end )
  ] as $found
  | ([ $found[] | select(.class == "expired") ])    as $expired
  | ([ $found[] | select(.class == "expiring") ])   as $expiring
  | ([ $found[] | select(.class == "unreadable") ]) as $unreadable
  |
  ( (if ($expired | length) > 0 then [{
        title: "Developer app consumer keys are expired in project `\($project)`",
        details: "\($expired | length) consumer key(s) in org `\($org)` have already expired. Consumers using them receive 401s.\n\nAffected apps:\n\(fmt_list($expired | map(.desc)))",
        severity: 3,
        next_steps: "Generate a new consumer key/secret for each affected app and rotate the credential in the consuming system.",
        expected: "Consumer keys should not be expired; they silently break consumer traffic",
        actual: "\($expired | length) expired consumer key(s) on: \(fmt_inline($expired | map(.app) | unique))",
        affected_count: ($expired | length),
        apps: ($expired | map(.app) | unique),
        issue_type: "credential_expired"
      }] else [] end)
    +
    (if ($expiring | length) > 0 then [{
        title: "Developer app consumer keys expire within \($warn_days) days in project `\($project)`",
        details: "\($expiring | length) consumer key(s) in org `\($org)` expire inside the \($warn_days)-day warning window. They should be rotated before expiry to avoid 401s.\n\nAffected apps:\n\(fmt_list($expiring | map(.desc)))",
        severity: 3,
        next_steps: "Rotate the consumer key/secret for each affected app before it expires. Consider alerting on key age.",
        expected: "Consumer keys should not expire within the warning window",
        actual: "\($expiring | length) consumer key(s) expiring on: \(fmt_inline($expiring | map(.app) | unique))",
        affected_count: ($expiring | length),
        apps: ($expiring | map(.app) | unique),
        issue_type: "credential_expiring"
      }] else [] end)
    +
    (if ($unreadable | length) > 0 then [{
        title: "Developer app consumer keys have an unreadable expiry in project `\($project)`",
        details: "\($unreadable | length) credential(s) in org `\($org)` report an expiresAt that is not an epoch-milliseconds value, so their expiry state could not be evaluated.\n\nAffected apps:\n\(fmt_list($unreadable | map(.desc)))",
        severity: 4,
        next_steps: "Inspect these credentials via the Apigee management API and confirm the expiresAt field.",
        expected: "Consumer key expiry should be readable as epoch milliseconds",
        actual: "\($unreadable | length) credential(s) with an unreadable expiry on: \(fmt_inline($unreadable | map(.app) | unique))",
        affected_count: ($unreadable | length),
        apps: ($unreadable | map(.app) | unique),
        issue_type: "credential_expiry_unreadable"
      }] else [] end)
  )
' > "$ISSUES_FILE"

apigee_write_status "$STATUS_FILE"
echo "Consumer-key expiry check complete. Evaluated $(printf '%s' "$apps" | jq 'length') app(s), found $(jq 'length' "$ISSUES_FILE") issue(s)."
