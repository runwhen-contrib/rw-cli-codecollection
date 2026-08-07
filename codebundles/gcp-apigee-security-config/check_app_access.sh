#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee Developer App Access Scope
#
# Reviews developer apps and their consumer keys for over-broad scopes,
# unusual status flags, and keys that pose an access-control risk.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#
# AUTH:
#   gcloud must be authenticated; token obtained via `gcloud auth print-access-token`.
#
# OUTPUTS:
#   app_access_issues.json - JSON array of issue objects
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="app_access_issues.json"
API="https://apigee.googleapis.com/v1"

echo "Checking developer app access scope for org: $APIGEE_ORG"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || gcloud auth application-default print-access-token 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
  echo "Error: unable to obtain an access token." >&2
  printf '[{"title":"Cannot access Apigee developer app data","details":"Unable to obtain a GCP access token for org `%s`.","severity":3,"expected":"Apigee API access should be authenticated","actual":"No access token available","next_steps":"Verify the service account is authenticated and has roles/apigee.readOnlyAdmin."}]\n' "$APIGEE_ORG" > "$OUTPUT_FILE"
  exit 0
fi

list_json()
{
  local url="$1"
  local raw
  raw=$(curl -s -H "Authorization: Bearer $TOKEN" "$url")
  printf '%s' "$raw" | jq -c 'if type=="array" then . elif .developer != null then .developer elif .app != null then .app else [] end' 2>/dev/null || echo "[]"
}

developers=$(list_json "$API/organizations/$APIGEE_ORG/developers")
if [ "$(printf '%s' "$developers" | jq 'if type=="array" then .|length else 0 end' 2>/dev/null)" -eq 0 ]; then
  echo "No developers found for org $APIGEE_ORG."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

printf '%s' "$developers" | jq -c '.[]' 2>/dev/null | while read -r dev_obj; do
  dev_email=$(printf '%s' "$dev_obj" | jq -r '.email // .developerId // empty')
  [ -z "$dev_email" ] && continue

  apps=$(list_json "$API/organizations/$APIGEE_ORG/developers/$dev_email/apps")
  if [ "$(printf '%s' "$apps" | jq 'if type=="array" then .|length else 0 end' 2>/dev/null)" -eq 0 ]; then
    continue
  fi

  printf '%s' "$apps" | jq -c '.[]' 2>/dev/null | while read -r app_ref; do
    app_name=$(printf '%s' "$app_ref" | jq -r '.name // empty')
    [ -z "$app_name" ] && continue
    app=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/organizations/$APIGEE_ORG/developers/$dev_email/apps/$app_name")
    app_status=$(printf '%s' "$app" | jq -r '.status // empty' 2>/dev/null)
    app_scopes=$(printf '%s' "$app" | jq -c '.scopes // []' 2>/dev/null)
    credentials=$(printf '%s' "$app" | jq -c '.credentials // []' 2>/dev/null)

    echo "  Developer $dev_email app: $app_name (status=$app_status)"

    # Over-broad app-level scopes (wildcard) paired with an active app
    if [ "$app_status" = "approved" ] || [ -z "$app_status" ]; then
      if printf '%s' "$app_scopes" | jq -e 'map(select(test("\\*|/\\*\\*"; "i"))) | length > 0' >/dev/null 2>&1; then
        scopes_list=$(printf '%s' "$app_scopes" | jq -c '.' 2>/dev/null)
        jq -n \
          --arg title "Apigee developer app \`$app_name\` (developer \`$dev_email\`) has over-broad scopes" \
          --arg details "Developer app '$app_name' owned by '$dev_email' in org '$APIGEE_ORG' declares broad/wildcard app scopes: $scopes_list. This may grant the app access beyond what is required." \
          --arg severity "3" \
          --arg expected "Developer apps should request only the specific scopes they need" \
          --arg actual "App declares broad scopes: $scopes_list" \
          --arg next_steps "Review and reduce the scopes requested by app '$app_name' to the minimum necessary, and rotate the consumer key if overly broad scope was active." \
          --arg app "$app_name" --arg dev "$dev_email" \
          '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,app:$app,developer:$dev,issue_type:"over_broad_app_scope"}' >> "$OUTPUT_FILE"
      fi
    fi

    # Inspect each consumer key
    printf '%s' "$credentials" | jq -c '.[]' 2>/dev/null | while read -r cred; do
      consumer_key=$(printf '%s' "$cred" | jq -r '.consumerKey // empty')
      cred_status=$(printf '%s' "$cred" | jq -r '.status // empty' 2>/dev/null)
      cred_scopes=$(printf '%s' "$cred" | jq -c '.scopes // []' 2>/dev/null)
      cred_products=$(printf '%s' "$cred" | jq -c '.apiProducts // []' 2>/dev/null)
      product_count=$(printf '%s' "$cred_products" | jq 'length' 2>/dev/null || echo 0)

      echo "    Consumer key ${consumer_key:0:8}... status=$cred_status"

      # Over-broad credential scopes on an approved key
      if [ "$cred_status" = "approved" ]; then
        if printf '%s' "$cred_scopes" | jq -e 'map(select(test("\\*|/\\*\\*"; "i"))) | length > 0' >/dev/null 2>&1; then
          cjson=$(printf '%s' "$cred_scopes" | jq -c '.' 2>/dev/null)
          jq -n \
            --arg title "Approved consumer key on app \`$app_name\` has over-broad scopes" \
            --arg details "An approved consumer key (${consumer_key:0:8}... on app '$app_name', developer '$dev_email', org '$APIGEE_ORG') carries broad/wildcard scopes: $cjson. This is an access-control risk." \
            --arg severity "3" \
            --arg expected "Approved consumer keys should have least-privilege scopes" \
            --arg actual "Approved key has broad scopes: $cjson" \
            --arg next_steps "Revoke and re-issue the consumer key with scoped permissions, or narrow the app's scopes to the minimum required." \
            --arg app "$app_name" --arg dev "$dev_email" \
            '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,app:$app,developer:$dev,issue_type:"over_broad_key_scope"}' >> "$OUTPUT_FILE"
        fi
      fi

      # Revoked / inactive consumer key still present on an active app
      if [ "$cred_status" = "revoked" ]; then
        jq -n \
          --arg title "Revoked (inactive) consumer key on app \`$app_name\`" \
          --arg details "A revoked consumer key (${consumer_key:0:8}...) is still attached to app '$app_name' (developer '$dev_email', org '$APIGEE_ORG'). Inactive keys should be cleaned up to reduce the attack surface." \
          --arg severity "2" \
          --arg expected "Consumer keys should be cleaned up when they are no longer needed" \
          --arg actual "Revoked consumer key remains on app '$app_name'" \
          --arg next_steps "Remove the revoked consumer key from app '$app_name', or the entire app if no longer used." \
          --arg app "$app_name" --arg dev "$dev_email" \
          '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,app:$app,developer:$dev,issue_type:"inactive_consumer_key"}' >> "$OUTPUT_FILE"
      fi
    done
  done
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Developer app access check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
