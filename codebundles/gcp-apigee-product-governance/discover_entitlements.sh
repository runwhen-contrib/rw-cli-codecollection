#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project owning the Apigee organization
#   APIGEE_ORG      - optional; resolved from GCP_PROJECT_ID when empty
#
# Discovers the org-wide entitlement surface of an Apigee X organization:
# API products, developers and developer apps (with their consumer keys).
# Writes a discovery snapshot to entitlements_discovery.json and a JSON array
# of issues (empty unless access fails) to entitlements_discovery_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/apigee_common.sh"

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
ISSUES_FILE="entitlements_discovery_issues.json"
SNAPSHOT_FILE="entitlements_discovery.json"

resolve_apigee_org
echo "Discovering Apigee entitlements for org: $APIGEE_ORG (project: $GCP_PROJECT_ID)"

issues_json='[]'
add_issue() {
  local title="$1" details="$2" severity="$3" next_steps="$4"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --arg severity "$severity" \
    --arg next_steps "$next_steps" \
    --arg expected "Apigee entitlements in org \`$APIGEE_ORG\` should be enumerable for governance checks" \
    --arg actual "$details" \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "next_steps": $next_steps,
       "expected": $expected,
       "actual": $actual,
       "org": $APIGEE_ORG,
       "issue_type": "discovery_access_error"
     }]')
}

# --- List API products -------------------------------------------------------
product_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/apiproducts?expand=true")"
api_products="$(echo "$product_payload" | jq_bag_to_array "apiProduct" "apiProducts")"
if [ "$(echo "$api_products" | jq 'length')" = "0" ] && [ "$(echo "$product_payload" | jq 'keys|length')" = "0" ]; then
  add_issue "Cannot Access API Products for org \`$APIGEE_ORG\`" \
    "The Apigee management API returned no API products for org \`$APIGEE_ORG\` in project \`$GCP_PROJECT_ID\`. Check credentials and the apigee.readOnlyAdmin role." \
    "2" "Verify the service account has roles/apigee.readOnlyAdmin on the organization and the org name is correct."
fi

# --- List developers ----------------------------------------------------------
dev_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/developers")"
developers="$(echo "$dev_payload" | jq_bag_to_array "developer")"
if [ "$(echo "$developers" | jq 'length')" = "0" ] && [ "$(echo "$dev_payload" | jq 'keys|length')" = "0" ]; then
  add_issue "Cannot Access Developers for org \`$APIGEE_ORG\`" \
    "The Apigee management API returned no developers for org \`$APIGEE_ORG\` in project \`$GCP_PROJECT_ID\`." \
    "2" "Verify the service account has roles/apigee.readOnlyAdmin on the organization."
fi

# --- List developer apps (org-scope, expanded) --------------------------------
apps_payload="$(APIGEE_ORG="$APIGEE_ORG" GCP_PROJECT_ID="$GCP_PROJECT_ID" apigee_checked_get \
  "organizations/$APIGEE_ORG/apps?expand=true")"
apps="$(echo "$apps_payload" | jq_bag_to_array "app")"
if [ "$(echo "$apps" | jq 'length')" = "0" ] && [ "$(echo "$apps_payload" | jq 'keys|length')" = "0" ]; then
  add_issue "Cannot Access Developer Apps for org \`$APIGEE_ORG\`" \
    "The Apigee management API returned no developer apps for org \`$APIGEE_ORG\` in project \`$GCP_PROJECT_ID\`." \
    "2" "Verify the service account has roles/apigee.readOnlyAdmin on the organization."
fi

product_count="$(echo "$api_products" | jq 'length')"
developer_count="$(echo "$developers" | jq 'length')"
app_count="$(echo "$apps" | jq 'length')"

# --- Write outputs ------------------------------------------------------------
echo "$issues_json" > "$ISSUES_FILE"

cat > "$SNAPSHOT_FILE" <<EOF
{
  "org": "$APIGEE_ORG",
  "project_id": "$GCP_PROJECT_ID",
  "api_product_count": $product_count,
  "developer_count": $developer_count,
  "app_count": $app_count,
  "api_products": $api_products,
  "developers": $developers,
  "apps": $apps
}
EOF

echo "Discovery complete."
echo "  API products: $product_count"
echo "  Developers:   $developer_count"
echo "  Apps:         $app_count"
echo "Issues detected: $(echo "$issues_json" | jq 'length')"
