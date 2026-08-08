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
# consumer traffic with 401s. Writes api_credentials_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
DEVELOPER_APPS="${DEVELOPER_APPS:-All}"
KEY_EXPIRY_WARNING_DAYS="${KEY_EXPIRY_WARNING_DAYS:-30}"
ISSUES_FILE="api_credentials_issues.json"

resolve_apigee_org
echo "Checking developer app consumer-key expiry in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

apps_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/apps?expand=true")"
all_apps="$(echo "$apps_payload" | jq_bag_to_array "app")"

if [ "$DEVELOPER_APPS" != "All" ] && [ -n "$DEVELOPER_APPS" ]; then
  filter="$(printf '%s' "$DEVELOPER_APPS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)"
  apps="$(echo "$all_apps" | jq --argjson names "$filter" \
    '[.[] | select(.name as $n | $names | index($n))]')"
else
  apps="$all_apps"
fi

> "$ISSUES_FILE"

now_ms="$(date +%s)000"
warn_ms=$((now_ms + KEY_EXPIRY_WARNING_DAYS * 86400000))

echo "$apps" | jq -c '.[]' | while read -r app; do
  [ -z "$app" ] && continue
  app_name=$(echo "$app" | jq -r '.name // "unknown"')
  dev_id=$(echo "$app" | jq -r '.developerId // "unknown"')
  echo "$app" | jq -c '.credentials[]?' | while read -r cred; do
    [ -z "$cred" ] && continue
    key_short=$(echo "$cred" | jq -r '.consumerKey // ""' | cut -c1-8)
    status=$(echo "$cred" | jq -r '.status // ""')
    expires_at_raw=$(echo "$cred" | jq -r '.expiresAt // "0"')
    expires_at="${expires_at_raw:-0}"

    # expiresAt == 0 means the key never expires (common default).
    if [ "$expires_at" = "0" ] || [ -z "$expires_at" ] || [ "$expires_at" = "null" ]; then
      continue
    fi

    # expiresAt is epoch milliseconds.
    if [ "$expires_at" -le "$now_ms" ]; then
      days_ago=$(( (now_ms - expires_at) / 86400000 ))
      printf '{"title":"Consumer key `%s...` on app `%s` is EXPIRED","details":"The consumer key on developer app `%s` (developer %s) in org `%s` expired approximately %s day(s) ago. Consumers will receive 401s.","severity":3,"next_steps":"Generate a new consumer key/secret for app `%s` and rotate the credential in the consuming system. Use: gcloud apigee apps ... or the management API to create a new credential.","expected":"Consumer keys should not be expired; they silently break consumer traffic","actual":"Consumer key on app `%s` is expired","app":"%s","issue_type":"credential_expired"}\n' \
        "$key_short" "$app_name" "$app_name" "$dev_id" "$APIGEE_ORG" "$days_ago" "$app_name" "$app_name" "$app_name" >> "$ISSUES_FILE"
    elif [ "$expires_at" -le "$warn_ms" ]; then
      days_left=$(( (expires_at - now_ms) / 86400000 ))
      printf '{"title":"Consumer key `%s...` on app `%s` expires in %s day(s)","details":"The consumer key on developer app `%s` (developer %s) in org `%s` expires in approximately %s day(s) (within the %s-day warning window). It should be rotated before expiry to avoid 401s.","severity":3,"next_steps":"Rotate the consumer key/secret for app `%s` before it expires. Consider setting an expiry policy or alerting on key age.","expected":"Consumer keys should not expire within the warning window","actual":"Consumer key on app `%s` expires within %s days","app":"%s","issue_type":"credential_expiring"}\n' \
        "$key_short" "$app_name" "$app_name" "$dev_id" "$APIGEE_ORG" "$days_left" "$KEY_EXPIRY_WARNING_DAYS" "$app_name" "$app_name" "$days_left" "$app_name" >> "$ISSUES_FILE"
    fi
  done
done

if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "Consumer-key expiry check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
