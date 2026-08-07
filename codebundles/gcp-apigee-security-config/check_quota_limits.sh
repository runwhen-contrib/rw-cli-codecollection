#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Check Apigee API Product Quota and Rate Limits
#
# Reviews every API product in the Apigee organization and flags products with
# no quota, an extreme quota (>= QUOTA_ABUSE_THRESHOLD), or auto-approval that
# weakens access control.
#
# REQUIRED ENV VARS:
#   APIGEE_ORG                    - Apigee organization name
#   GCP_PROJECT_ID                - GCP project ID hosting the Apigee runtime
#   QUOTA_ABUSE_THRESHOLD         - Quota value at/above which it is flagged (default 1000000)
#
# AUTH:
#   gcloud must be authenticated; token obtained via `gcloud auth print-access-token`.
#
# OUTPUTS:
#   quota_limits_issues.json - JSON array of issue objects
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${APIGEE_ORG:?Must set APIGEE_ORG}"
: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${QUOTA_ABUSE_THRESHOLD:=1000000}"

OUTPUT_FILE="quota_limits_issues.json"
API="https://apigee.googleapis.com/v1"

echo "Checking API product quota/rate limits for org: $APIGEE_ORG (abuse threshold: $QUOTA_ABUSE_THRESHOLD)"

TOKEN=$(gcloud auth print-access-token 2>/dev/null || gcloud auth application-default print-access-token 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
  echo "Error: unable to obtain an access token." >&2
  printf '[{"title":"Cannot access Apigee API product data","details":"Unable to obtain a GCP access token for org `%s`.","severity":3,"expected":"Apigee API access should be authenticated","actual":"No access token available","next_steps":"Verify the service account is authenticated and has roles/apigee.readOnlyAdmin."}]\n' "$APIGEE_ORG" > "$OUTPUT_FILE"
  exit 0
fi

list_json()
{
  local url="$1"
  local raw
  raw=$(curl -s -H "Authorization: Bearer $TOKEN" "$url")
  printf '%s' "$raw" | jq -c 'if type=="array" then . elif .apiProduct != null then .apiProduct else [] end' 2>/dev/null || echo "[]"
}

products=$(list_json "$API/organizations/$APIGEE_ORG/apiproducts")
if [ "$(printf '%s' "$products" | jq 'if type=="array" then .|length else 0 end' 2>/dev/null)" -eq 0 ]; then
  echo "No API products found for org $APIGEE_ORG."
  echo "[]" > "$OUTPUT_FILE"
  exit 0
fi

> "$OUTPUT_FILE"

printf '%s' "$products" | jq -c '.[]' 2>/dev/null | while read -r prod_ref; do
  prod_name=$(printf '%s' "$prod_ref" | jq -r '.name // empty')
  [ -z "$prod_name" ] && continue
  prod=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/organizations/$APIGEE_ORG/apiproducts/$prod_name")

  quota=$(printf '%s' "$prod" | jq -r '.quota // empty' 2>/dev/null)
  quota_interval=$(printf '%s' "$prod" | jq -r '.quotaInterval // empty' 2>/dev/null)
  quota_time_unit=$(printf '%s' "$prod" | jq -r '.quotaTimeUnit // empty' 2>/dev/null)
  approval_type=$(printf '%s' "$prod" | jq -r '.approvalType // empty' 2>/dev/null)

  echo "  API product: $prod_name (quota=$quota/$quota_interval ${quota_time_unit}, approval=$approval_type)"

  # No quota set
  if [ -z "$quota" ] || [ "$quota" = "null" ]; then
    jq -n \
      --arg title "Apigee API product \`$prod_name\` has no quota/rate limit configured" \
      --arg details "API product '$prod_name' in org '$APIGEE_ORG' has no quota set. Consumers of this product can make unbounded requests, which can overrun upstream backends or allow abusive traffic." \
      --arg severity "3" \
      --arg expected "API products should define a quota and rate limit" \
      --arg actual "No quota configured for product '$prod_name'" \
      --arg next_steps "Configure a quota (quota, quotaInterval, quotaTimeUnit) on API product '$prod_name' to bound request rate." \
      --arg product "$prod_name" \
      '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,product:$product,issue_type:"no_quota"}' >> "$OUTPUT_FILE"
  else
    # Extreme quota
    if [ "$quota" -ge "$QUOTA_ABUSE_THRESHOLD" ] 2>/dev/null; then
      jq -n \
        --arg title "Apigee API product \`$prod_name\` has an excessive quota of $quota" \
        --arg details "API product '$prod_name' in org '$APIGEE_ORG' has quota $quota (per ${quota_interval} ${quota_time_unit}), which is at or above the abuse threshold of $QUOTA_ABUSE_THRESHOLD. This may allow abusive or runaway traffic." \
        --arg severity "2" \
        --arg expected "API product quotas should be set to reasonable values below the abuse threshold" \
        --arg actual "Quota $quota >= threshold $QUOTA_ABUSE_THRESHOLD" \
        --arg next_steps "Lower the quota on API product '$prod_name' to a value below $QUOTA_ABUSE_THRESHOLD and review whether such a high limit is warranted." \
        --arg product "$prod_name" \
        '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,product:$product,issue_type:"excessive_quota"}' >> "$OUTPUT_FILE"
    fi
  fi

  # Auto approval weakens access control
  if [ "$approval_type" = "auto" ]; then
    jq -n \
      --arg title "Apigee API product \`$prod_name\` uses auto-approval" \
      --arg details "API product '$prod_name' in org '$APIGEE_ORG' has approvalType 'auto', so developer apps are automatically approved without review. This can grant unintended access to the APIs exposed by this product." \
      --arg severity "2" \
      --arg expected "API products should require manual review of access requests" \
      --arg actual "approvalType is 'auto' for product '$prod_name'" \
      --arg next_steps "Set the product's approval type to 'manual' so access requests go through a review process." \
      --arg product "$prod_name" \
      '{title:$title,details:$details,severity:($severity|tonumber),expected:$expected,actual:$actual,next_steps:$next_steps,product:$product,issue_type:"auto_approval"}' >> "$OUTPUT_FILE"
  fi
done

if [ -s "$OUTPUT_FILE" ]; then
  jq -s '.' "$OUTPUT_FILE" > "${OUTPUT_FILE}.tmp" && mv "${OUTPUT_FILE}.tmp" "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi

echo "Quota/rate-limit check complete. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
