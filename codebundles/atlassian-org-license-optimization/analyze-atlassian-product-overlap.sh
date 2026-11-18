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
#   MIN_OVERLAP_PRODUCTS (default 2)
#   PRODUCTS (default All)
# -----------------------------------------------------------------------------

: "${ATLASSIAN_ORG_ID:?Must set ATLASSIAN_ORG_ID}"
: "${ATLASSIAN_ORG_NAME:?Must set ATLASSIAN_ORG_NAME}"
: "${INACTIVE_DAYS_THRESHOLD:=90}"
: "${MIN_OVERLAP_PRODUCTS:=2}"
: "${PRODUCTS:=All}"

OUTPUT_FILE="atlassian_product_overlap_issues.json"
SUMMARY_FILE="atlassian_product_overlap_summary.txt"
issues_json='[]'

source "$(dirname "$0")/atlassian-api-helpers.sh"

echo "Analyzing overlapping product entitlements for: ${ATLASSIAN_ORG_NAME}"
echo "Minimum licensed products for overlap: ${MIN_OVERLAP_PRODUCTS}"

if ! ensure_user_inventory; then
  issues_json=$(append_api_access_issue "$issues_json" "Failed to fetch managed user inventory.")
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

overlap_report=$(jq \
  --argjson threshold "$INACTIVE_DAYS_THRESHOLD" \
  --argjson min_products "$MIN_OVERLAP_PRODUCTS" \
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
    select(($pa | length) >= $min_products) |
    ($pa | map({
      key: .key,
      days: days_since_iso(.last_active),
      active: (days_since_iso(.last_active) < $threshold)
    })) as $stats |
    {
      account_id: ($user.account_id // $user.accountId),
      name: ($user.name // $user.email),
      email: ($user.email // ""),
      licensed: ($stats | map(.key)),
      active_on: ($stats | map(select(.active)) | map(.key)),
      redundant: ($stats | map(select(.active | not)) | map(.key))
    } |
    select((.redundant | length) > 0)
  ]' "$INVENTORY_CACHE_FILE")

overlap_count=$(echo "$overlap_report" | jq 'length')

{
  echo "Product Overlap Analysis — ${ATLASSIAN_ORG_NAME}"
  echo "================================================="
  echo "Users with ${MIN_OVERLAP_PRODUCTS}+ licensed products but inactive on some: ${overlap_count}"
  echo ""
  echo "Note: Under Teamwork Collection licensing, duplicate product rows may not imply duplicate billing."
  echo "      Consolidate access when users are active on only a subset of assigned products."
  echo ""
  echo "$overlap_report" | jq -r 'limit(15; .[]) | "- \(.name) <\(.email)>: licensed=\(.licensed | join(",")) active_on=\(.active_on | join(",")) redundant=\(.redundant | join(","))"'
} > "$SUMMARY_FILE"
cat "$SUMMARY_FILE"

if [[ "$overlap_count" -ge 5 ]]; then
  severity=3
elif [[ "$overlap_count" -ge 1 ]]; then
  severity=2
else
  severity=0
fi

if [[ "$severity" -ge 2 ]]; then
  details=$(cat "$SUMMARY_FILE")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Overlapping Product Entitlements in Atlassian Organization \`${ATLASSIAN_ORG_NAME}\`" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "In Atlassian Administration > Directory, review users with multiple product assignments. Revoke redundant product access for users active on fewer products. For Teamwork Collection, confirm whether seats are counted per unique user before removing access." \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": $severity,
      "next_steps": $next_steps
    }]')
fi

echo "$overlap_report" | jq '.' > atlassian_product_overlap_data.json
echo "$issues_json" > "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
