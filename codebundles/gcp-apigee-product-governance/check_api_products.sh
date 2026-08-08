#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project owning the Apigee organization
#   APIGEE_ORG      - optional; resolved from GCP_PROJECT_ID when empty
#   APIPRODUCTS     - optional; comma-separated product names or 'All' (default)
#
# Flags API products that weaken or break the intended access-control/quota
# contract:
#   - auto-approval enabled (unapproved access allowed)            -> severity 2
#   - missing or zero quota / rate limit                           -> severity 3
# Writes a JSON array of issues to api_products_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
APIPRODUCTS="${APIPRODUCTS:-All}"
ISSUES_FILE="api_products_issues.json"

resolve_apigee_org
echo "Checking API products in org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

# --- Build a filtered product list -------------------------------------------
product_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/apiproducts?expand=true")"
all_products="$(echo "$product_payload" | jq_bag_to_array "apiProduct" "apiProducts")"

if [ "$APIPRODUCTS" != "All" ] && [ -n "$APIPRODUCTS" ]; then
  filter="$(printf '%s' "$APIPRODUCTS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)"
  products="$(echo "$all_products" | jq --argjson names "$filter" \
    '[.[] | select(.name as $n | $names | index($n))]')"
else
  products="$all_products"
fi

> "$ISSUES_FILE"

# --- Evaluate each product -----------------------------------------------------
echo "$products" | jq -c '.[]' | while read -r prod; do
  [ -z "$prod" ] && continue
  name=$(echo "$prod" | jq -r '.name // "unknown"')
  display=$(echo "$prod" | jq -r '.displayName // .name // "unknown"')
  approval_type=$(echo "$prod" | jq -r '.approvalType // ""')
  quota=$(echo "$prod" | jq -r '.quota // ""')
  quota_interval=$(echo "$prod" | jq -r '.quotaInterval // "0"')
  quota_unit=$(echo "$prod" | jq -r '.quotaTimeUnit // ""')

  # Product allows auto-approval -> unapproved access is permitted.
  if [ "$approval_type" = "auto" ]; then
    printf '{"title":"API product `%s` permits auto-approval of access","details":"API product `%s` in org `%s` has approvalType `auto`, allowing developer apps to gain access without manual review. This weakens the access-control posture.","severity":2,"next_steps":"Review product `%s` in the Apigee console and switch approvalType to `manual` unless self-service access is an explicit requirement.","expected":"API products should require manual approval unless auto-approval is intentional","actual":"API product `%s` uses auto-approval","product":"%s","issue_type":"auto_approval"}\n' \
      "$name" "$display" "$APIGEE_ORG" "$name" "$name" "$name" >> "$ISSUES_FILE"
  fi

  # Missing/zero quota -> rate limits are not enforced.
  quota_int="$(printf '%s' "${quota:-0}" | tr -d '[:space:]')"
  quota_int="${quota_int:-0}"
  if [ "$quota_int" = "0" ] || [ -z "$quota" ]; then
    printf '{"title":"API product `%s` has no quota/rate limit configured","details":"API product `%s` in org `%s` has quota set to `%s`%s, so no rate limit is enforced by this product. This can allow runaway usage or break intended limits.","severity":3,"next_steps":"Confirm whether the product intentionally relies on a shared/quota policy. If not, set an explicit quota (quota, quotaInterval, quotaTimeUnit) on product `%s`.","expected":"API products should define a non-zero quota so rate limits are enforced","actual":"API product `%s` has no quota configured","product":"%s","issue_type":"missing_quota"}\n' \
      "$name" "$display" "$APIGEE_ORG" "$quota" "${quota_unit:+ ($quota_unit)}" "$name" "$name" "$name" >> "$ISSUES_FILE"
  fi
done

if [ -s "$ISSUES_FILE" ]; then
  jq -s '.' "$ISSUES_FILE" > "${ISSUES_FILE}.tmp" && mv "${ISSUES_FILE}.tmp" "$ISSUES_FILE"
else
  echo "[]" > "$ISSUES_FILE"
fi

echo "API product check complete. Found $(jq length "$ISSUES_FILE") issue(s)."
