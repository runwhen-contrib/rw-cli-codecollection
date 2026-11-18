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
#   LOOKBACK_DAYS               Days of logs to analyze (default: 7)
#   LOG_ANALYTICS_WORKSPACE_ID  Workspace resource ID (auto-discovered when empty)
# -----------------------------------------------------------------------------

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${AZURE_STORAGE_ACCOUNT_NAME:?Must set AZURE_STORAGE_ACCOUNT_NAME}"

LOOKBACK_DAYS="${LOOKBACK_DAYS:-7}"
LOG_ANALYTICS_WORKSPACE_ID="${LOG_ANALYTICS_WORKSPACE_ID:-}"
OUTPUT_FILE="access_logs_output.json"
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

is_private_ip() {
  local ip="$1"
  python3 - "$ip" <<'PY'
import ipaddress, sys
ip = sys.argv[1]
try:
    addr = ipaddress.ip_address(ip)
    print("1" if addr.is_private or addr.is_loopback or addr.is_link_local else "0")
except ValueError:
    print("0")
PY
}

echo "Querying StorageBlobLogs for ${AZURE_STORAGE_ACCOUNT_NAME} (last ${LOOKBACK_DAYS} days)" >&2

az account set --subscription "$AZURE_SUBSCRIPTION_ID" 2>/dev/null || true

storage_info=$(az storage account show \
  --name "$AZURE_STORAGE_ACCOUNT_NAME" \
  --resource-group "$AZURE_RESOURCE_GROUP" \
  --subscription "$AZURE_SUBSCRIPTION_ID" \
  -o json 2>/dev/null || echo "")

if [[ -z "$storage_info" || "$storage_info" == "null" ]]; then
  add_issue \
    "Cannot access storage account for log analysis \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "Storage account should be readable" \
    "az storage account show failed" \
    "Verify account and permissions." \
    "Confirm storage account exists." \
    "az storage account show --name ${AZURE_STORAGE_ACCOUNT_NAME} --resource-group ${AZURE_RESOURCE_GROUP}"
  jq -n --argjson issues "$issues_json" \
    '{issues: $issues, risk_assessment: {safe_to_disable_public_access: false, safe_to_disable_shared_key: false, rationale: "Account inaccessible"}, summary: {diagnostic_settings_enabled: false}}' \
    > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

resource_id=$(echo "$storage_info" | jq -r '.id')
blob_resource_id="${resource_id}/blobServices/default"
portal_url="https://portal.azure.com/#@/resource${resource_id}/logs"
account_name_lower=$(echo "$AZURE_STORAGE_ACCOUNT_NAME" | tr '[:upper:]' '[:lower:]')
timespan="P${LOOKBACK_DAYS}D"

diagnostic_settings=$(az monitor diagnostic-settings list --resource "$blob_resource_id" -o json 2>/dev/null || echo "[]")
diagnostic_enabled=false
workspace_id="$LOG_ANALYTICS_WORKSPACE_ID"

if [[ -n "$diagnostic_settings" && "$diagnostic_settings" != "[]" ]]; then
  ws_from_diag=$(echo "$diagnostic_settings" | jq -r '.[].workspaceId // empty' | head -1)
  storage_logs_enabled=$(echo "$diagnostic_settings" | jq '[.[] | .logs[]? | select(.category == "StorageRead" or .category == "StorageWrite" or .category == "StorageDelete") | select(.enabled == true)] | length')
  if [[ -n "$ws_from_diag" ]]; then
    workspace_id="$ws_from_diag"
    diagnostic_enabled=true
  fi
  if [[ "$storage_logs_enabled" -gt 0 ]]; then
    diagnostic_enabled=true
  fi
fi

if [[ -z "$workspace_id" ]]; then
  echo "Attempting workspace auto-discovery from resource group..." >&2
  workspace_id=$(az monitor log-analytics workspace list \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --query "[0].id" -o tsv 2>/dev/null || echo "")
fi

if [[ "$diagnostic_enabled" != "true" ]]; then
  add_issue \
    "StorageBlobLogs diagnostic settings not enabled for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    1 \
    "Storage blob logs should be forwarded to Log Analytics for caller identification" \
    "No diagnostic settings forwarding StorageRead/Write/Delete logs to Log Analytics" \
    "Enable diagnostic settings on blobServices/default with StorageRead, StorageWrite, and StorageDelete categories." \
    "Configure diagnostic settings: Portal > Storage Account > Monitoring > Diagnostic settings > Add > Send to Log Analytics workspace." \
    "az monitor diagnostic-settings list --resource ${blob_resource_id}"
  jq -n \
    --argjson issues "$issues_json" \
    --arg portal_url "$portal_url" \
    '{
      issues: $issues,
      risk_assessment: {
        safe_to_disable_public_access: false,
        safe_to_disable_shared_key: false,
        rationale: "Access logs unavailable; enable StorageBlobLogs diagnostic settings before remediation"
      },
      summary: {
        diagnostic_settings_enabled: false,
        workspace_id: null
      },
      portal_url: $portal_url
    }' > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

echo "Using Log Analytics workspace: ${workspace_id}" >&2

kql="StorageBlobLogs
| where TimeGenerated > ago(${LOOKBACK_DAYS}d)
| where AccountName =~ '${account_name_lower}'
| summarize RequestCount=count() by CallerIpAddress, AuthenticationType, Identity, UserPrincipalName, ObjectId, OperationName
| order by RequestCount desc
| take 100"

log_results=$(timeout 120 az monitor log-analytics query \
  --workspace "$workspace_id" \
  --analytics-query "$kql" \
  --timespan "$timespan" \
  -o json 2>log_query.err || echo "[]")

if echo "$log_results" | grep -qiE 'AuthorizationFailed|403|Forbidden'; then
  err_msg=$(cat log_query.err 2>/dev/null || echo "Authorization failure")
  add_issue \
    "Log Analytics query blocked for \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    3 \
    "Log Analytics Reader should allow StorageBlobLogs queries" \
    "Query returned authorization failure" \
    "${err_msg}" \
    "Grant Log Analytics Reader on workspace ${workspace_id}." \
    "az monitor log-analytics query --workspace ${workspace_id} --analytics-query \"StorageBlobLogs | take 1\""
  jq -n --argjson issues "$issues_json" --arg workspace_id "$workspace_id" --arg portal_url "$portal_url" \
    '{issues: $issues, risk_assessment: {safe_to_disable_public_access: false, safe_to_disable_shared_key: false, rationale: "Log query blocked"}, summary: {diagnostic_settings_enabled: true, workspace_id: $workspace_id}, portal_url: $portal_url}' \
    > "$OUTPUT_FILE"
  cat "$OUTPUT_FILE"
  exit 0
fi

rows=$(echo "$log_results" | jq '. // []')
row_count=$(echo "$rows" | jq 'length')

safe_public=true
safe_shared_key=true
rationale_parts=()

anonymous_external=0
anonymous_internal=0
account_key_callers=0

if [[ "$row_count" -gt 0 ]]; then
  while IFS= read -r row; do
    auth_type=$(echo "$row" | jq -r '.AuthenticationType // .authenticationType // ""')
    caller_ip=$(echo "$row" | jq -r '.CallerIpAddress // .callerIpAddress // ""')
    count=$(echo "$row" | jq -r '.RequestCount // .requestCount // 0')

    if [[ "$auth_type" =~ [Aa]nonymous ]]; then
      if [[ "$(is_private_ip "$caller_ip")" == "1" ]]; then
        anonymous_internal=$((anonymous_internal + count))
      else
        anonymous_external=$((anonymous_external + count))
      fi
    fi
    if [[ "$auth_type" =~ [Aa]ccountKey ]]; then
      account_key_callers=$((account_key_callers + 1))
    fi
  done < <(echo "$rows" | jq -c '.[]')
fi

caller_summary=$(echo "$rows" | jq '[.[] | {
  caller_ip: (.CallerIpAddress // .callerIpAddress),
  auth: (.AuthenticationType // .authenticationType),
  identity: (.Identity // .identity // .UserPrincipalName // .ObjectId // "unknown"),
  operation: (.OperationName // .operationName),
  requests: (.RequestCount // .requestCount)
}]')

if [[ "$anonymous_external" -gt 0 ]]; then
  add_issue \
    "Anonymous blob access from external IPs on \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    2 \
    "No anonymous access from public IP addresses before disabling public blob access" \
    "${anonymous_external} anonymous request(s) from external IPs in last ${LOOKBACK_DAYS} day(s)" \
    "External anonymous traffic indicates active public blob/container consumption." \
    "Identify public containers and external consumers; notify owners before disabling allowBlobPublicAccess." \
    "StorageBlobLogs | where AuthenticationType == \"Anonymous\" | summarize count() by CallerIpAddress"
  safe_public=false
  rationale_parts+=("Anonymous external IP traffic")
elif [[ "$anonymous_internal" -gt 0 ]]; then
  add_issue \
    "Anonymous blob access from internal IPs on \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    3 \
    "Anonymous access should be eliminated before public access disablement" \
    "${anonymous_internal} anonymous request(s) from private/internal IPs" \
    "Internal anonymous traffic may originate from VNet-integrated workloads or private endpoints." \
    "Trace internal anonymous callers via Identity and OperationName fields before remediation." \
    "StorageBlobLogs | where AuthenticationType == \"Anonymous\" | summarize count() by CallerIpAddress, Identity"
  safe_public=false
  rationale_parts+=("Anonymous internal IP traffic")
fi

distinct_account_key=$(echo "$rows" | jq '[.[] | select((.AuthenticationType // .authenticationType // "") | test("AccountKey"; "i")) | (.CallerIpAddress // .callerIpAddress // "unknown")] | unique | length')
if [[ "$distinct_account_key" -gt 1 ]]; then
  add_issue \
    "Multiple distinct AccountKey callers on \`${AZURE_STORAGE_ACCOUNT_NAME}\`" \
    4 \
    "AccountKey callers should be inventoried before shared key disablement" \
    "${distinct_account_key} distinct caller IP(s) using AccountKey authentication" \
    "Multiple AccountKey sources increase remediation coordination effort." \
    "Contact owners of each caller IP/identity and migrate to OAuth or managed identity." \
    "StorageBlobLogs | where AuthenticationType == \"AccountKey\" | summarize count() by CallerIpAddress, Identity"
  safe_shared_key=false
  rationale_parts+=("Multiple AccountKey callers")
fi

rationale="StorageBlobLogs analyzed over ${LOOKBACK_DAYS} day(s). ${row_count} aggregated caller row(s)."
if [[ ${#rationale_parts[@]} -gt 0 ]]; then
  rationale="${rationale} $(IFS='; '; echo "${rationale_parts[*]}")."
else
  rationale="${rationale} No anonymous or multi-AccountKey blockers detected in logs."
fi

jq -n \
  --argjson issues "$issues_json" \
  --argjson caller_summary "$caller_summary" \
  --argjson row_count "$row_count" \
  --arg workspace_id "$workspace_id" \
  --arg portal_url "$portal_url" \
  --argjson safe_public "$safe_public" \
  --argjson safe_shared_key "$safe_shared_key" \
  --arg rationale "$rationale" \
  --argjson lookback_days "$LOOKBACK_DAYS" \
  '{
    issues: $issues,
    risk_assessment: {
      safe_to_disable_public_access: $safe_public,
      safe_to_disable_shared_key: $safe_shared_key,
      rationale: $rationale
    },
    summary: {
      diagnostic_settings_enabled: true,
      workspace_id: $workspace_id,
      lookback_days: $lookback_days,
      aggregated_rows: $row_count,
      callers: $caller_summary
    },
    portal_url: $portal_url
  }' > "$OUTPUT_FILE"

cat "$OUTPUT_FILE"
