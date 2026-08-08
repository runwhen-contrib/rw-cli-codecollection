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
# Writes developer_status_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ISSUES_FILE="developer_status_issues.json"

resolve_apigee_org
echo "Checking developer status and dangling references in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

apps_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/apps?expand=true")"
apps="$(echo "$apps_payload" | jq_bag_to_array "app")"

product_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/apiproducts?expand=true")"
products="$(echo "$product_payload" | jq_bag_to_array "apiProduct" "apiProducts")"

> "$ISSUES_FILE"

# --- Existing product name set ------------------------------------------------
existing_products="$(echo "$products" | jq -r '[.[].name] | unique')"

# --- Dangling product references from app credentials -------------------------
echo "$apps" | jq -c '.[]' | while read -r app; do
  [ -z "$app" ] && continue
  app_name=$(echo "$app" | jq -r '.name // "unknown"')
  echo "$app" | jq -c '.credentials[]?' | while read -r cred; do
    [ -z "$cred" ] && continue
    key_short=$(echo "$cred" | jq -r '.consumerKey // ""' | cut -c1-8)
    echo "$cred" | jq -c '.apiProducts[]?' | while read -r ap; do
      [ -z "$ap" ] && continue
      pname=$(echo "$ap" | jq -r '.apiproduct // ""')
      if [ -n "$pname" ]; then
        exists=$(echo "$existing_products" | jq --arg p "$pname" '[ .[] | select(. == $p) ] | length')
        if [ "$exists" = "0" ]; then
          printf '{"title":"App `%s` references a non-existent API product `%s`","details":"Developer app `%s` in org `%s` has a consumer key (`%s...`) attached to API product `%s`, which no longer exists in the organization. This is a dangling access-control reference.","severity":3,"next_steps":"Remove the broken product association from app `%s` and update the credential to reference a valid API product.","expected":"App credentials should only reference API products that currently exist","actual":"App `%s` references missing API product `%s`","app":"%s","issue_type":"dangling_product_ref"}\n' \
            "$app_name" "$pname" "$app_name" "$APIGEE_ORG" "$key_short" "$pname" "$app_name" "$app_name" "$pname" "$app_name" >> "$ISSUES_FILE"
        fi
      fi
    done
  done
done

# --- Developer status vs. attached apps ---------------------------------------
# Identify developers that own apps from the org-level app list, then check the
# developer detail for status drift. Only app-owning developers need a lookup.
owning_devs="$(echo "$apps" | jq -r '[.[].developerId?] | unique')"
dev_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/developers")"
developers="$(echo "$dev_payload" | jq_bag_to_array "developer")"

dev_id_count="$(echo "$owning_devs" | jq 'length')"
if [ "$dev_id_count" -gt 0 ]; then
  echo "$developers" | jq -c --argjson ids "$owning_devs" '.[] | select(.developerId as $d | $ids | index($d))' | while read -r dev; do
    [ -z "$dev" ] && continue
    dev_id="$(echo "$dev" | jq -r '.developerId // ""')"
    email="$(echo "$dev" | jq -r '.email // .userName // "unknown"')"
    status="$(echo "$dev" | jq -r '.status // ""')"
    app_count="$(echo "$dev" | jq -r '.appCount // "0"' | tr -d '[:space:]')"
    app_count="${app_count:-0}"

    if [ "$status" != "active" ] && [ -n "$status" ]; then
      if [ "$app_count" = "0" ] && ! echo "$owning_devs" | jq -e --arg d "$dev_id" 'index($d)' >/dev/null 2>&1; then
        continue
      fi
      printf '{"title":"Developer `%s` is %s while their apps are attached","details":"Developer `%s` (id %s) in org `%s` has status `%s`, but the org still counts or carries developer apps. This access-control drift can leave orphaned active entitlements.","severity":3,"next_steps":"Review developer `%s` status. Deactivate or revoke the app credentials if the developer should no longer consume the APIs.","expected":"Inactive/blocked developers should not have active apps or credentials","actual":"Developer `%s` is %s with apps attached","developer":"%s","issue_type":"developer_status_drift"}\n' \
          "$email" "$status" "$email" "$dev_id" "$APIGEE_ORG" "$status" "$email" "$email" "$status" "$email" >> "$ISSUES_FILE"
    fi
  done
fi

if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "Developer status/dangling-reference check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
