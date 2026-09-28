#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   ATLASSIAN_ORG_ID
#   ATLASSIAN_ORG_NAME
#
# OPTIONAL:
#   INACTIVE_DAYS_THRESHOLD (default 90)
#   PRODUCTS (default All)
#   TIMEOUT_SECONDS
# -----------------------------------------------------------------------------

: "${ATLASSIAN_ORG_ID:?Must set ATLASSIAN_ORG_ID}"
: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"
: "${INACTIVE_DAYS_THRESHOLD:=90}"
: "${PRODUCTS:=All}"

OUTPUT_FILE="atlassian_inactive_billable_issues.json"
SUMMARY_FILE="atlassian_inactive_billable_summary.txt"
issues_json='[]'

source "$(dirname "$0")/atlassian-api-helpers.sh"

echo "Identifying inactive billable users for organization: ${ATLASSIAN_ORG_NAME} (${ATLASSIAN_ORG_ID})"
echo "Inactive threshold: ${INACTIVE_DAYS_THRESHOLD} days"
echo "Products filter: ${PRODUCTS}"

if ! ensure_user_inventory; then
  issues_json=$(append_api_access_issue "$issues_json" "Failed to fetch managed user inventory from GET /v1/orgs/{orgId}/users.")
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "API access failure. See ${OUTPUT_FILE}" > "$SUMMARY_FILE"
  exit 0
fi

inactive_users=$(jq \
  --argjson threshold "$INACTIVE_DAYS_THRESHOLD" \
  --arg products "$PRODUCTS" \
  'def days_since_iso($iso):
     if ($iso // "") == "" then 999999
     else (($iso | sub("\\.[0-9]+"; "") | fromdateiso8601?) as $ts |
       if $ts == null then 999999 else (((now - $ts) / 86400) | floor) end) end;
   def product_allowed($key):
     if $products == "All" or $products == "" then true
     else ($products | split(",") | map(gsub(" "; "")) | index($key)) != null end;
   [.users[] | select(.access_billable == true) | . as $user |
    ($user.product_access // []) | map(select(.key != null and product_allowed(.key))) as $pa |
    if ($pa | length) == 0 then
      {account_id: ($user.account_id // $user.accountId), name: ($user.name // $user.email), email: ($user.email // ""),
       department: ($user.department // "unknown"), licensed_products: [], days_since_activity: 999999, inactive: true}
    else
      ($pa | map({key: .key, days: days_since_iso(.last_active)})) as $stats |
      {
        account_id: ($user.account_id // $user.accountId),
        name: ($user.name // $user.email),
        email: ($user.email // ""),
        department: ($user.department // "unknown"),
        licensed_products: ($stats | map(.key)),
        days_since_activity: ($stats | map(.days) | min),
        inactive: (all($stats[]; .days >= $threshold))
      }
    end |
    select(.inactive)
  ]' "$INVENTORY_CACHE_FILE")

total_billable=$(jq '[.users[] | select(.access_billable == true)] | length' "$INVENTORY_CACHE_FILE")
total_inactive=$(echo "$inactive_users" | jq 'length')

inactive_by_product=$(echo "$inactive_users" | jq '
  [.[].licensed_products[]?] | group_by(.) | map({key: .[0], value: length}) | from_entries
')

{
  echo "Inactive Billable Users Analysis — ${ATLASSIAN_ORG_NAME}"
  echo "============================================================"
  echo "Billable users scanned: ${total_billable}"
  echo "Inactive billable users (>${INACTIVE_DAYS_THRESHOLD}d): ${total_inactive}"
  echo ""
  echo "By product:"
  echo "$inactive_by_product" | jq -r 'to_entries[]? | "- \(.key): \(.value)"' 2>/dev/null || echo "(none)"
  echo ""
  echo "Sample inactive users (up to 10):"
  echo "$inactive_users" | jq -r 'limit(10; .[]) | "- \(.name) <\(.email)> products=\(.licensed_products | join(",")) days=\(.days_since_activity) dept=\(.department)"'
} > "$SUMMARY_FILE"
cat "$SUMMARY_FILE"

if [[ "$total_inactive" -ge 5 ]]; then
  severity=3
elif [[ "$total_inactive" -ge 1 ]]; then
  severity=2
else
  severity=0
fi

if [[ "$severity" -ge 2 ]]; then
  details=$(cat "$SUMMARY_FILE")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Inactive Billable Users in Atlassian Organization \`${ATLASSIAN_ORG_NAME}\`" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "Review inactive users in Atlassian Administration > Directory > Managed accounts. Suspend access before removal to preserve group memberships. Path: admin.atlassian.com/o/${ATLASSIAN_ORG_ID}/users. Consider revoking product access for users inactive >${INACTIVE_DAYS_THRESHOLD} days." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": $severity,
      "next_steps": $next_steps
    }]')
fi

echo "$inactive_users" | jq '.' > atlassian_inactive_billable_data.json
echo "$issues_json" > "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
