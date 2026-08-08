#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID        - GCP project owning the Apigee organization
#   APIGEE_ORG            - optional; resolved from GCP_PROJECT_ID when empty
#   USAGE_LOOKBACK_DAYS   - optional; analytics lookback window (default 30)
#
# Identifies orphaned / unused entitlements for housekeeping (severity 4):
#   - API products with no developer app attached
#   - developer apps with no consumer keys
#   - developer apps with no recorded traffic (Analytics developer_app
#     dimension over the lookback window) -- best effort; skipped if the
#     Analytics API is unavailable.
# Writes orphaned_entitlements_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
USAGE_LOOKBACK_DAYS="${USAGE_LOOKBACK_DAYS:-30}"
ISSUES_FILE="orphaned_entitlements_issues.json"

resolve_apigee_org
echo "Checking orphaned/unused entitlements in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

apps_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/apps?expand=true")"
apps="$(echo "$apps_payload" | jq_bag_to_array "app")"

product_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/apiproducts?expand=true")"
products="$(echo "$product_payload" | jq_bag_to_array "apiProduct" "apiProducts")"

> "$ISSUES_FILE"

# --- Developer apps with no consumer keys -------------------------------------
echo "$apps" | jq -c '.[]' | while read -r app; do
  [ -z "$app" ] && continue
  app_name=$(echo "$app" | jq -r '.name // "unknown"')
  dev_id=$(echo "$app" | jq -r '.developerId // "unknown"')
  cred_count=$(echo "$app" | jq '[.credentials[]?] | length')
  if [ "$cred_count" = "0" ]; then
    printf '{"title":"Developer app `%s` has no consumer keys","details":"Developer app `%s` (developer %s) in org `%s` has no consumer keys/credentials attached, so it cannot consume any API product.","severity":4,"next_steps":"Verify the app is still needed. If it is not, remove app `%s`; if it should be active, generate a consumer key for it.","expected":"Developer apps should have at least one consumer key if they are intended for use","actual":"Developer app `%s` has no consumer keys","app":"%s","issue_type":"app_no_keys"}\n' \
      "$app_name" "$app_name" "$dev_id" "$APIGEE_ORG" "$app_name" "$app_name" "$app_name" >> "$ISSUES_FILE"
  fi
done

# --- Referenced product set (from app credential associations) ----------------
referenced_products="$(echo "$apps" | jq -r '[.[].credentials[]?.apiProducts[]?.apiproduct] | unique')"

# --- Orphaned API products ----------------------------------------------------
if [ "$(echo "$referenced_products" | jq 'length')" -gt 0 ]; then
  echo "$products" | jq -c --argjson refs "$referenced_products" '.[]' | while read -r prod; do
    [ -z "$prod" ] && continue
    pname=$(echo "$prod" | jq -r '.name // "unknown"')
    refd=$(echo "$referenced_products" | jq --arg p "$pname" '[ .[] | select(. == $p) ] | length')
    if [ "$refd" = "0" ]; then
      printf '{"title":"API product `%s` is orphaned (no developer app attached)","details":"API product `%s` in org `%s` is not referenced by any developer-app credential and can be considered for retirement.","severity":4,"next_steps":"Confirm the product is no longer needed by any consumer, then delete or archive product `%s`.","expected":"API products should be referenced by at least one developer-app credential","actual":"API product `%s` is not referenced by any developer app","product":"%s","issue_type":"orphaned_product"}\n' \
        "$pname" "$pname" "$APIGEE_ORG" "$pname" "$pname" "$pname" >> "$ISSUES_FILE"
    fi
  done
fi

# --- Unused developer apps (Analytics developer_app cross-reference) ----------
usage_checked="false"
used_apps_file="$(mktemp)"
: > "$used_apps_file"

env_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/environments")"
environments="$(echo "$env_payload" | jq_bag_to_array "environment")"
env_count="$(echo "$environments" | jq 'length')"

if [ "$env_count" -gt 0 ]; then
  end_gmt="$(date -u +"%m/%d/%Y %H:%M")"
  start_gmt="$(date -u -d "$USAGE_LOOKBACK_DAYS days ago" +"%m/%d/%Y %H:%M" 2>/dev/null || date -u +"%m/%d/%Y %H:%M")"
  tr_start="$(printf '%s' "$start_gmt" | sed 's/ /%20/')"
  tr_end="$(printf '%s' "$end_gmt" | sed 's/ /%20/')"

  echo "$environments" | jq -r '.[]' | while read -r env; do
    [ -z "$env" ] && continue
    stats="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
      "organizations/$APIGEE_ORG/environments/$env/stats/developer_app?select=sum(message_count)&timeRange=$tr_start~$tr_end&timeUnit=month")"
    dim=$(echo "$stats" | jq -r '.environments[0].dimensions[]?.name // empty' 2>/dev/null || true)
    if [ -n "$dim" ]; then
      echo "$dim" >> "$used_apps_file"
    fi
  done
  if [ -s "$used_apps_file" ]; then
    sort -u "$used_apps_file" -o "$used_apps_file"
    usage_checked="true"
  fi
fi

if [ "$usage_checked" = "true" ]; then
  echo "$apps" | jq -c '.[]' | while read -r app; do
    [ -z "$app" ] && continue
    app_name=$(echo "$app" | jq -r '.name // "unknown"')
    if ! grep -qxF "$app_name" "$used_apps_file"; then
      printf '{"title":"Developer app `%s` is unused (no traffic in %s days)","details":"Developer app `%s` in org `%s` recorded no API traffic in the last %s day(s) according to the Analytics developer_app dimension.","severity":4,"next_steps":"Confirm whether app `%s` is still required. If not, remove it to reduce the entitlement surface; if expected traffic is missing, investigate.","expected":"Developer apps should see traffic within the lookback window if they are actively used","actual":"Developer app `%s` saw no traffic in the lookback window","app":"%s","issue_type":"unused_app"}\n' \
        "$app_name" "$USAGE_LOOKBACK_DAYS" "$app_name" "$APIGEE_ORG" "$USAGE_LOOKBACK_DAYS" "$app_name" "$app_name" "$app_name" >> "$ISSUES_FILE"
    fi
  done
else
  echo "Analytics developer_app usage cross-reference skipped (no environment data or permission)."
fi

rm -f "$used_apps_file"

if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "Orphaned/unused entitlement check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
