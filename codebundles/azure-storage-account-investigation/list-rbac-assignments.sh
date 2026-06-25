#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   AZURE_STORAGE_ACCOUNT_NAME
#
# Lists RBAC role assignments for a storage account including inherited scopes.
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_STORAGE_ACCOUNT_NAME:?Must set AZURE_STORAGE_ACCOUNT_NAME}"

OUTPUT_FILE="rbac_assignments_output.json"
issues_json='[]'

add_issue() {
  local title="$1" severity="$2" expected="$3" actual="$4" details="$5" next_steps="$6"
  local reproduce_hint="${7:-}"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg expected "$expected" \
    --arg actual "$actual" \
    --arg details "$details" \
    --arg next_steps "$next_steps" \
    --arg reproduce_hint "$reproduce_hint" \
    --argjson severity "$severity" \
    '. += [{
      title: $title,
      severity: $severity,
      expected: $expected,
      actual: $actual,
      details: $details,
      next_steps: $next_steps,
      reproduce_hint: $reproduce_hint
    }]')
}

safe_to_disable_public_access=true
safe_to_disable_shared_key=true
rationale_parts=()

echo "Listing RBAC assignments for storage account: ${AZURE_STORAGE_ACCOUNT_NAME}" >&2

az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || {
  add_issue \
    "Cannot set Azure subscription context for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Azure CLI should authenticate and set subscription context" \
    "az account set failed for subscription ${AZURE_SUBSCRIPTION_ID}" \
    "Verify azure_credentials secret and subscription ID." \
    "Confirm service principal has Reader access on subscription ${AZURE_SUBSCRIPTION_ID}." \
    "az account set --subscription ${AZURE_SUBSCRIPTION_ID}"
  jq -n \
    --argjson issues "$issues_json" \
    --arg portal_url "" \
    '{issues: $issues, risk_assessment: {safe_to_disable_public_access: false, safe_to_disable_shared_key: false, rationale: "Unable to authenticate"}, summary: {assignment_count: 0}, portal_url: $portal_url}' \
    > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
}

storage_info=$(az storage account show \
  --name "$AZURE_STORAGE_ACCOUNT_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  -o json 2>storage_show.err || true)

if [[ -z "$storage_info" || "$storage_info" == "null" ]]; then
  err_msg=$(cat storage_show.err 2>/dev/null || echo "Unknown error")
  add_issue \
    "Cannot access storage account \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Storage account should be readable with provided credentials" \
    "az storage account show failed: ${err_msg}" \
    "Account: ${AZURE_STORAGE_ACCOUNT_NAME}, Resource group: ${AZURE_RESOURCE_GROUP}" \
    "Verify account name, resource group, and Reader permissions on the storage account." \
    "az storage account show --name ${AZURE_STORAGE_ACCOUNT_NAME} --resource-group ${AZURE_RESOURCE_GROUP}"
  jq -n \
    --argjson issues "$issues_json" \
    '{issues: $issues, risk_assessment: {safe_to_disable_public_access: false, safe_to_disable_shared_key: false, rationale: "Storage account not accessible"}, summary: {assignment_count: 0}}' \
    > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

resource_id=$(echo "$storage_info" | jq -r '.id')
portal_url="https://portal.azure.com/#@/resource${resource_id}/users"
allow_blob_public_access=$(echo "$storage_info" | jq -r '.allowBlobPublicAccess // true')
shared_key_access=$(echo "$storage_info" | jq -r '.allowSharedKeyAccess // true')

echo "Storage account resource ID: ${resource_id}" >&2
echo "Portal IAM: ${portal_url}" >&2

rbac_assignments=$(az role assignment list \
  --scope "$resource_id" \
  --include-inherited \
  --all \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  -o json 2>rbac.err || echo "[]")

if [[ ! "$rbac_assignments" =~ ^\[ ]]; then
  err_msg=$(cat rbac.err 2>/dev/null || echo "Unknown RBAC error")
  if echo "$err_msg" | grep -qiE 'AuthorizationFailed|403|Forbidden'; then
    add_issue \
      "RBAC enumeration blocked for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
      3 \
      "Reader and Microsoft.Authorization/roleAssignments/read should allow RBAC listing" \
      "Role assignment list returned authorization failure" \
      "${err_msg}" \
      "Grant Reader plus roleAssignments/read on subscription or storage account scope before remediation." \
      "az role assignment list --scope ${resource_id} --include-inherited --all"
  else
    add_issue \
      "Failed to list RBAC assignments for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
      3 \
      "RBAC assignments should be enumerable" \
      "az role assignment list failed" \
      "${err_msg}" \
      "Verify permissions and retry RBAC enumeration." \
      "az role assignment list --scope ${resource_id} --include-inherited --all"
  fi
  jq -n \
    --argjson issues "$issues_json" \
    --arg portal_url "$portal_url" \
    '{issues: $issues, risk_assessment: {safe_to_disable_public_access: false, safe_to_disable_shared_key: false, rationale: "RBAC data unavailable"}, summary: {assignment_count: 0}, portal_url: $portal_url}' \
    > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

assignment_count=$(echo "$rbac_assignments" | jq 'length')
echo "Found ${assignment_count} RBAC assignment(s)" >&2

summary_by_type=$(echo "$rbac_assignments" | jq '[group_by(.principalType)[] | {principalType: .[0].principalType, count: length}]')
summary_by_role=$(echo "$rbac_assignments" | jq '[group_by(.roleDefinitionName)[] | {role: .[0].roleDefinitionName, count: length}] | sort_by(-.count)')

data_plane_roles='["Storage Blob Data Contributor","Storage Blob Data Reader","Storage Blob Data Owner","Storage Queue Data Contributor","Storage Queue Data Reader","Storage Table Data Contributor","Storage Table Data Reader","Storage File Data SMB Share Contributor","Storage File Data SMB Share Reader"]'

# Owner/Contributor at resource scope (not inherited)
resource_scope_privileged=$(echo "$rbac_assignments" | jq --arg rid "$resource_id" '
  [.[] | select(.scope == $rid and (.roleDefinitionName == "Owner" or .roleDefinitionName == "Contributor"))]
')
resource_scope_count=$(echo "$resource_scope_privileged" | jq 'length')
if [[ "$resource_scope_count" -gt 0 ]]; then
  principals=$(echo "$resource_scope_privileged" | jq -r '[.[].principalName] | join(", ")')
  add_issue \
    "Over-privileged RBAC at storage account scope for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    3 \
    "Owner/Contributor should not be assigned directly at storage account resource scope" \
    "${resource_scope_count} Owner/Contributor assignment(s) at resource scope" \
    "Principals: ${principals}. Full list in summary.assignments." \
    "Replace Owner/Contributor with least-privilege storage data-plane or control-plane roles before disabling public access or shared keys." \
    "az role assignment list --scope ${resource_id} --include-inherited false"
  safe_to_disable_public_access=false
  safe_to_disable_shared_key=false
  rationale_parts+=("Owner/Contributor assigned at storage account scope")
fi

# User principals with data-plane roles
user_data_plane=$(echo "$rbac_assignments" | jq --argjson roles "$data_plane_roles" '
  [.[] | select(.principalType == "User" and (.roleDefinitionName as $r | $roles | index($r)))]
')
user_data_plane_count=$(echo "$user_data_plane" | jq 'length')
if [[ "$user_data_plane_count" -gt 0 ]]; then
  users=$(echo "$user_data_plane" | jq -r '[.[].principalName] | unique | join(", ")')
  add_issue \
    "User accounts with storage data-plane access on \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Automated workloads should use managed identities or service principals instead of user data-plane roles" \
    "${user_data_plane_count} user data-plane role assignment(s)" \
    "Users: ${users}. Contact these principals before disabling shared key or public blob access." \
    "Review user data-plane assignments and migrate to OAuth-based managed identity access where possible." \
    "az role assignment list --scope ${resource_id} --include-inherited --all"
  safe_to_disable_shared_key=false
  rationale_parts+=("User principals hold data-plane roles")
fi

# Informational: all data-plane role holders
all_data_plane=$(echo "$rbac_assignments" | jq --argjson roles "$data_plane_roles" '
  [.[] | select(.roleDefinitionName as $r | $roles | index($r))]
')
data_plane_count=$(echo "$all_data_plane" | jq 'length')
if [[ "$data_plane_count" -gt 0 ]]; then
  holder_summary=$(echo "$all_data_plane" | jq -r '[.[] | "\(.principalName) (\(.roleDefinitionName))"] | join("; ")')
  add_issue \
    "Storage data-plane role holders for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Data-plane role holders should be documented before remediation" \
    "${data_plane_count} data-plane role assignment(s) identified" \
    "Holders: ${holder_summary}" \
    "Coordinate with listed principals before disabling public access or shared key authentication." \
    "az role assignment list --scope ${resource_id} --include-inherited --all"
fi

if [[ "$allow_blob_public_access" == "true" ]]; then
  safe_to_disable_public_access=false
  rationale_parts+=("allowBlobPublicAccess is enabled")
fi

if [[ "$shared_key_access" == "true" && "$user_data_plane_count" -gt 0 ]]; then
  safe_to_disable_shared_key=false
fi

rationale="RBAC review complete. ${assignment_count} assignment(s) enumerated."
if [[ ${#rationale_parts[@]} -gt 0 ]]; then
  rationale="${rationale} Concerns: $(IFS='; '; echo "${rationale_parts[*]}")."
else
  rationale="${rationale} No over-privileged resource-scope Owner/Contributor or user data-plane blockers detected."
fi

echo "RBAC analysis complete. Issues: $(echo "$issues_json" | jq 'length')" >&2

jq -n \
  --argjson issues "$issues_json" \
  --argjson assignments "$rbac_assignments" \
  --argjson summary_by_type "$summary_by_type" \
  --argjson summary_by_role "$summary_by_role" \
  --arg portal_url "$portal_url" \
  --argjson safe_public "$([ "$safe_to_disable_public_access" = true ] && echo true || echo false)" \
  --argjson safe_shared_key "$([ "$safe_to_disable_shared_key" = true ] && echo true || echo false)" \
  --arg rationale "$rationale" \
  --argjson assignment_count "$assignment_count" \
  '{
    issues: $issues,
    risk_assessment: {
      safe_to_disable_public_access: $safe_public,
      safe_to_disable_shared_key: $safe_shared_key,
      rationale: $rationale
    },
    summary: {
      assignment_count: $assignment_count,
      by_principal_type: $summary_by_type,
      by_role: $summary_by_role,
      assignments: $assignments
    },
    portal_url: $portal_url
  }' > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
