#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_SUBSCRIPTION_ID
#   AZURE_RESOURCE_GROUP
#   AZURE_STORAGE_ACCOUNT_NAME
#
# OPTIONAL:
#   ADDITIONAL_SUBSCRIPTION_IDS  Comma-separated subscription IDs for cross-sub queries
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_STORAGE_ACCOUNT_NAME:?Must set AZURE_STORAGE_ACCOUNT_NAME}"

ADDITIONAL_SUBSCRIPTION_IDS="${ADDITIONAL_SUBSCRIPTION_IDS:-}"
OUTPUT_FILE="dependencies_output.json"
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

merge_graph_results() {
  local combined='[]'
  while IFS= read -r chunk; do
    [[ -z "$chunk" || "$chunk" == "null" ]] && continue
    combined=$(echo "$combined" | jq --argjson chunk "$chunk" '. + $chunk')
  done
  echo "$combined" | jq 'unique_by(.id)'
}

echo "Querying Resource Graph dependencies for: ${AZURE_STORAGE_ACCOUNT_NAME}" >&2

az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true

storage_info=$(az storage account show \
  --name "$AZURE_STORAGE_ACCOUNT_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  -o json 2>/dev/null || echo "")

if [[ -z "$storage_info" || "$storage_info" == "null" ]]; then
  add_issue \
    "Cannot resolve storage account for dependency mapping \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Storage account metadata required for dependency queries" \
    "az storage account show failed" \
    "Verify account name and permissions." \
    "Confirm storage account exists and credentials have Reader access." \
    "az storage account show --name ${AZURE_STORAGE_ACCOUNT_NAME} --resource-group ${AZURE_RESOURCE_GROUP}"
  jq -n --argjson issues "$issues_json" \
    '{issues: $issues, risk_assessment: {safe_to_disable_public_access: false, safe_to_disable_shared_key: false, rationale: "Account not found"}, summary: {dependency_count: 0, dependencies: []}}' \
    > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

resource_id=$(echo "$storage_info" | jq -r '.id')
portal_url="https://portal.azure.com/#@/resource${resource_id}"
primary_blob=$(echo "$storage_info" | jq -r '.primaryEndpoints.blob // empty' | sed 's|https://||; s|/$||')
primary_dfs=$(echo "$storage_info" | jq -r '.primaryEndpoints.dfs // empty' | sed 's|https://||; s|/$||')
account_name_lower=$(echo "$AZURE_STORAGE_ACCOUNT_NAME" | tr '[:upper:]' '[:lower:]')

subscriptions=("$AZURE_SUBSCRIPTION_ID")
if [[ -n "$ADDITIONAL_SUBSCRIPTION_IDS" ]]; then
  IFS=',' read -ra extra_subs <<< "$ADDITIONAL_SUBSCRIPTION_IDS"
  for sub in "${extra_subs[@]}"; do
    sub=$(echo "$sub" | xargs)
    [[ -n "$sub" ]] && subscriptions+=("$sub")
  done
fi
sub_args=()
for sub in "${subscriptions[@]}"; do
  sub_args+=(--subscriptions "$sub")
done

echo "Searching subscriptions: ${subscriptions[*]}" >&2

# Query 1: property references (name + blob/dfs FQDN)
prop_query="Resources
| where id !~ '${resource_id}'
| where tostring(properties) contains '${account_name_lower}'
    or (isnotempty('${primary_blob}') and tostring(properties) contains '${primary_blob}')
    or (isnotempty('${primary_dfs}') and tostring(properties) contains '${primary_dfs}')
| project id, name, type, resourceGroup, subscriptionId, location"

prop_result=$(az graph query -q "$prop_query" "${sub_args[@]}" -o json 2>/dev/null | jq '.data // []' || echo '[]')

# Query 2: private endpoint connections targeting this storage account
pe_query="Resources
| where type == 'microsoft.network/privateendpoints'
| mv-expand plc = properties.privateLinkServiceConnections
| where tostring(plc.properties.privateLinkServiceId) =~ '${resource_id}'
| project id, name, type, resourceGroup, subscriptionId, location"

pe_result=$(az graph query -q "$pe_query" "${sub_args[@]}" -o json 2>/dev/null | jq '.data // []' || echo '[]')

# Query 3: diagnostic settings referencing this storage account as log destination
diag_query="Resources
| where type == 'microsoft.insights/diagnosticsettings'
| where tostring(properties) contains '${account_name_lower}'
    or tostring(properties) contains '${resource_id}'
| project id, name, type, resourceGroup, subscriptionId, location"

diag_result=$(az graph query -q "$diag_query" "${sub_args[@]}" -o json 2>/dev/null | jq '.data // []' || echo '[]')

dependencies=$(merge_graph_results <<< "$(echo "$prop_result"; echo "$pe_result"; echo "$diag_result")")
dependency_count=$(echo "$dependencies" | jq 'length')

echo "Found ${dependency_count} dependent resource(s) via Resource Graph" >&2

blind_spots="Resource Graph cannot see Key Vault secret references, Databricks mount paths, application code, Terraform state backends, or SAS tokens embedded outside Azure resource properties."

dependency_list=$(echo "$dependencies" | jq '[.[] | {
  id: .id,
  name: .name,
  type: .type,
  resourceGroup: .resourceGroup,
  subscriptionId: .subscriptionId,
  portal_url: ("https://portal.azure.com/#@/resource" + .id)
}]')

if [[ "$dependency_count" -gt 5 ]]; then
  top_names=$(echo "$dependencies" | jq -r '[.[].name][0:8] | join(", ")')
  add_issue \
    "High blast radius: ${dependency_count} dependents reference \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    2 \
    "Fewer than 6 direct Azure resource dependencies before disabling public access" \
    "${dependency_count} dependent resources found via Resource Graph" \
    "Sample dependents: ${top_names}. ${blind_spots}" \
    "Review each dependent resource before disabling public blob access or shared key auth. Expand search with ADDITIONAL_SUBSCRIPTION_IDS if workloads span subscriptions." \
    "az graph query -q \"Resources | where tostring(properties) contains '${account_name_lower}'\""
elif [[ "$dependency_count" -ge 1 ]]; then
  dep_summary=$(echo "$dependencies" | jq -r '[.[] | "\(.name) (\(.type))"] | join("; ")')
  add_issue \
    "Moderate blast radius: ${dependency_count} dependent resource(s) for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    3 \
    "Understand all dependents before configuration changes" \
    "${dependency_count} dependent resource(s) found" \
    "Dependents: ${dep_summary}. ${blind_spots}" \
    "Validate each dependent still functions after disabling public access or shared keys." \
    "az graph query -q \"Resources | where tostring(properties) contains '${account_name_lower}'\""
else
  add_issue \
    "No Resource Graph dependencies found for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Dependency mapping should confirm whether hidden consumers exist" \
    "0 dependents returned by Resource Graph (property, private endpoint, diagnostic queries)" \
    "${blind_spots} Zero graph hits does not prove the account is unused." \
    "Supplement Resource Graph with access logs and transaction metrics before remediation." \
    "az graph query -q \"Resources | where tostring(properties) contains '${account_name_lower}'\""
fi

safe_public=$([ "$dependency_count" -le 5 ] && echo true || echo false)
safe_shared_key=$([ "$dependency_count" -le 5 ] && echo true || echo false)
rationale="Resource Graph mapped ${dependency_count} dependent resource(s). ${blind_spots}"

jq -n \
  --argjson issues "$issues_json" \
  --argjson dependencies "$dependency_list" \
  --argjson dependency_count "$dependency_count" \
  --arg portal_url "$portal_url" \
  --argjson safe_public "$safe_public" \
  --argjson safe_shared_key "$safe_shared_key" \
  --arg rationale "$rationale" \
  --arg blind_spots "$blind_spots" \
  '{
    issues: $issues,
    risk_assessment: {
      safe_to_disable_public_access: $safe_public,
      safe_to_disable_shared_key: $safe_shared_key,
      rationale: $rationale
    },
    summary: {
      dependency_count: $dependency_count,
      dependencies: $dependencies,
      blind_spots: $blind_spots,
      queries_run: ["property_references", "private_endpoints", "diagnostic_settings"]
    },
    portal_url: $portal_url
  }' > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
