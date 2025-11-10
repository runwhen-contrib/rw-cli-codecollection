#!/bin/bash
#
# Gather APIM Diagnostics & Logs from Log Analytics, highlighting known errors
#
# Usage:
#   export AZ_RESOURCE_GROUP="myResourceGroup"
#   export APIM_NAME="myApimInstance"
#   # Optional:
#   #   WARNINGS_THRESHOLD => integer threshold for each error type (default=1)
#   #   TIME_RANGE => e.g. 1h, 2h, 1d, etc. (default=1h)
#   #   AZURE_RESOURCE_SUBSCRIPTION_ID => set subscription ID
#   ./apim_diagnostic_logs.sh
#
# Description:
#   - Ensures subscription context
#   - Retrieves APIM Resource ID, checks diagnostic settings for a Log Analytics workspace
#   - Searches AzureDiagnostics for well-known errors/warnings in GatewayLogs or AuditLogs
#   - Breaks down each recognized error type, e.g. "BackendServiceUnreachable", "JwtValidationFailed"
#   - If any error type count > threshold, logs an issue
#   - Writes output to apim_diagnostic_log_issues.json => { "issues": [...] }

set -eo pipefail

###############################################################################
# 1) Subscription context & environment checks
###############################################################################
if [ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]; then
  subscription=$(az account show --query "id" -o tsv)
  echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
  echo "Using specified subscription ID: $subscription"
fi

echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || {
  echo "Failed to set subscription."
  exit 1
}

: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APIM_NAME:?Must set APIM_NAME}"

WARNINGS_THRESHOLD="${WARNINGS_THRESHOLD:-1}"
TIME_RANGE="${TIME_RANGE:-1h}"
OUTPUT_FILE="apim_diagnostic_log_issues.json"
issues_json='{"issues": []}'

echo "[INFO] Enhanced APIM Diagnostic Log Analysis for \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\` (Time Range: $TIME_RANGE)..."

###############################################################################
# 2) Retrieve APIM resource ID
###############################################################################
echo "[INFO] Retrieving APIM resource ID..."
apim_resource_id=""
if ! apim_resource_id=$(az apim show \
      --name "$APIM_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --query "id" -o tsv 2>apim_show_err.log); then
  err_msg=$(cat apim_show_err.log)
  rm -f apim_show_err.log
  echo "ERROR: Could not fetch APIM resource ID."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Failed to Retrieve APIM Resource ID for \`$APIM_NAME\`" \
    --arg d "$err_msg. Azure Portal: https://portal.azure.com" \
    --arg s "1" \
    --arg n "Check APIM name \`$APIM_NAME\` and RG \`$AZ_RESOURCE_GROUP\` or verify permissions" \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f apim_show_err.log

if [[ -z "$apim_resource_id" ]]; then
  echo "No resource ID returned. Possibly the APIM doesn't exist."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "APIM Resource \`$APIM_NAME\` Not Found" \
    --arg d "az apim show returned empty ID. Azure Portal: https://portal.azure.com" \
    --arg s "1" \
    --arg n "Check name/RG or create APIM" \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi

# Construct Azure portal URL for the APIM resource
PORTAL_URL="https://portal.azure.com/#@/resource${apim_resource_id}/overview"

echo "[INFO] APIM Resource ID: $apim_resource_id"
echo "[INFO] Azure Portal URL: $PORTAL_URL"

###############################################################################
# 3) Check Diagnostic Settings for Log Analytics
###############################################################################
echo "[INFO] Checking diagnostic settings for $apim_resource_id"
diag_settings_json=$(az monitor diagnostic-settings list \
  --resource "$apim_resource_id" -o json 2>diag_err.log || true)

if [[ -z "$diag_settings_json" || "$diag_settings_json" == "[]" ]]; then
  echo "[WARN] No diagnostic settings found for APIM."
  err_msg=$(cat diag_err.log)
  rm -f diag_err.log
  issues_json=$(echo "$issues_json" | jq \
    --arg t "No Diagnostic Settings Configured for APIM \`$APIM_NAME\`" \
    --arg d "No diagnostic settings route logs to Log Analytics. Log analysis unavailable. $err_msg. Azure Portal: $PORTAL_URL" \
    --arg s "4" \
    --arg n "Note: Configure diagnostic settings for APIM \`$APIM_NAME\` to enable log-based troubleshooting" \
    --arg portal "$PORTAL_URL" \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "portal_url": $portal,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi
rm -f diag_err.log

ws_resource_id=$(echo "$diag_settings_json" | jq -r '.[] | select(.workspaceId != null) | .workspaceId' | head -n 1)
if [[ -z "$ws_resource_id" || "$ws_resource_id" == "null" ]]; then
  echo "[WARN] No Log Analytics workspace found in diag settings."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "No Log Analytics Workspace Configured for APIM \`$APIM_NAME\`" \
    --arg d "Diagnostic settings exist but none route to a Log Analytics workspace. Cannot perform log queries. Azure Portal: $PORTAL_URL" \
    --arg s "4" \
    --arg n "Note: Configure Log Analytics workspace for APIM \`$APIM_NAME\` to enable log-based troubleshooting" \
    --arg portal "$PORTAL_URL" \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "portal_url": $portal,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi
echo "[INFO] Found workspace resource ID: $ws_resource_id"

###############################################################################
# 4) Convert workspace ID to Log Analytics GUID
###############################################################################
if ! workspace_id=$(az monitor log-analytics workspace show \
      --ids "$ws_resource_id" \
      --query "customerId" -o tsv 2>la_guid_err.log); then
  err_msg=$(cat la_guid_err.log)
  rm -f la_guid_err.log
  echo "ERROR: Could not retrieve workspace GUID."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Failed to Retrieve Workspace GUID for APIM \`$APIM_NAME\`" \
    --arg d "$err_msg. Azure Portal: $PORTAL_URL" \
    --arg s "1" \
    --arg n "Check roles or validity of workspace ID for RG \`$AZ_RESOURCE_GROUP\`" \
    --arg portal "$PORTAL_URL" \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "portal_url": $portal,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f la_guid_err.log
echo "[INFO] Workspace GUID: $workspace_id"

###############################################################################
# 5) Check available diagnostic log categories and build enhanced queries
###############################################################################
echo "[INFO] Checking available diagnostic log categories..."

# Check what log categories are available in the workspace
available_categories=$(az monitor log-analytics query \
  --workspace "$workspace_id" \
  --analytics-query "search in (AzureDiagnostics) TimeGenerated >= ago(${TIME_RANGE}) | where ResourceId == \"${apim_resource_id}\" | distinct Category" \
  -o json 2>/dev/null | jq -r 'if type == "array" then .[] | .tables[0].rows[]?[0]? else .tables[0].rows[]?[0]? end // empty' | sort -u)

echo "[INFO] Available log categories: $available_categories"

# Build category list for query
category_list="\"GatewayLogs\""
additional_categories=""

if echo "$available_categories" | grep -q "DeveloperPortalAuditLogs"; then
  category_list="$category_list, \"DeveloperPortalAuditLogs\""
  additional_categories="$additional_categories DeveloperPortalAuditLogs"
fi

if echo "$available_categories" | grep -q "WebSocketConnectionLogs"; then
  category_list="$category_list, \"WebSocketConnectionLogs\""
  additional_categories="$additional_categories WebSocketConnectionLogs"
fi

if echo "$available_categories" | grep -q "GatewayLlmLogs"; then
  category_list="$category_list, \"GatewayLlmLogs\""
  additional_categories="$additional_categories GatewayLlmLogs"
fi

# Note what categories are not available
missing_categories=""
for cat in "DeveloperPortalAuditLogs" "WebSocketConnectionLogs" "GatewayLlmLogs"; do
  if ! echo "$available_categories" | grep -q "$cat"; then
    missing_categories="$missing_categories $cat"
  fi
done

if [[ -n "$missing_categories" ]]; then
  echo "[INFO] Note: The following log categories are not configured:$missing_categories"
fi

###############################################################################
# 6) Enhanced Kusto Query for known APIM errors/warnings across all categories
###############################################################################
KUSTO_QUERY=$(cat <<EOF
AzureDiagnostics
| where TimeGenerated >= ago(${TIME_RANGE})
| where Category in ($category_list)
| where ResourceId == "${apim_resource_id}"
| where Level in ("Error","Warning")
| extend KnownErrorType = case(
    Message has "Backend service unreachable","BackendServiceUnreachable",
    Message has "JWT validation failed","JwtValidationFailed",
    Message has "operation timed out","BackendOperationTimedOut",
    Message has "invalid certificate","InvalidCertificate",
    Message has "WebSocket connection failed","WebSocketConnectionFailed",
    Message has "Developer portal authentication failed","DevPortalAuthFailed",
    Message has "LLM request failed","LLMRequestFailed",
    "OtherError"
)
| summarize CountOfMatches = count(), LastSeen = max(TimeGenerated) by KnownErrorType, Category
EOF
)

echo "[INFO] Kusto Query for known APIM errors:"
echo "$KUSTO_QUERY"

###############################################################################
# 7) Run the log query
###############################################################################
if ! query_output=$(az monitor log-analytics query \
      --workspace "$workspace_id" \
      --analytics-query "$KUSTO_QUERY" \
      -o json 2>la_query_err.log); then
  err_msg=$(cat la_query_err.log)
  rm -f la_query_err.log
  echo "ERROR: Log Analytics query failed."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Failed APIM Log Analytics Query for \`$APIM_NAME\`" \
    --arg d "$err_msg. Azure Portal: $PORTAL_URL" \
    --arg s "1" \
    --arg n "Check query syntax or ensure logs appear in the workspace for RG \`$AZ_RESOURCE_GROUP\`" \
    --arg portal "$PORTAL_URL" \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "portal_url": $portal,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f la_query_err.log

echo "[INFO] Raw query output:"
echo "$query_output"

###############################################################################
# 8) Parse each KnownErrorType row => [ KnownErrorType, CountOfMatches, Category ]
#    We'll create an issue if CountOfMatches > WARNINGS_THRESHOLD
###############################################################################
# Handle case when query_output is an empty array [] or has tables structure
rows_len=$(echo "$query_output" | jq -r 'if type == "array" and length == 0 then 0 elif type == "array" then (.[0].tables[0].rows | length) else (.tables[0].rows | length) end // 0')
if [[ "$rows_len" == "null" || -z "$rows_len" ]]; then
  rows_len=0
fi

for (( i=0; i<rows_len; i++ )); do
  # Detect output format - new Azure CLI returns array of objects directly
  first_element_type=$(echo "$query_output" | jq -r 'if type == "array" and length > 0 then (.[0] | type) else "null" end')
  
  if [[ "$first_element_type" == "object" ]]; then
    # New format: extract from object fields
    error_type=$(echo "$query_output" | jq -r ".[$i].KnownErrorType // \"UnknownError\"")
    count_val=$(echo "$query_output" | jq -r ".[$i].CountOfMatches // \"0\"")
    category=$(echo "$query_output" | jq -r ".[$i].Category // \"Unknown\"")
    observed_at=$(echo "$query_output" | jq -r ".[$i].LastSeen // \"Unknown\"")
  else
    # Old format: extract from tables[0].rows array
    error_type=$(echo "$query_output" | jq -r "if type == \"array\" then (if length > 0 then .[0].tables[0].rows[$i][0] else \"UnknownError\" end) else .tables[0].rows[$i][0] end // \"UnknownError\"")
    count_val=$(echo "$query_output" | jq -r "if type == \"array\" then (if length > 0 then .[0].tables[0].rows[$i][1] else 0 end) else .tables[0].rows[$i][1] end // 0")
    category=$(echo "$query_output" | jq -r "if type == \"array\" then (if length > 0 then .[0].tables[0].rows[$i][2] else \"Unknown\" end) else .tables[0].rows[$i][2] end // \"Unknown\"")
    observed_at=$(echo "$query_output" | jq -r "if type == \"array\" then (if length > 0 then .[0].tables[0].rows[$i][3] else \"Unknown\" end) else .tables[0].rows[$i][3] end // \"${date +%Y-%m-%dT%H:%M:%SZ}\"")
  fi
  
  echo "[INFO] Found error type \`$error_type\` in \`$category\` => count=$count_val observed_at=$observed_at"

  # If count_val > threshold => log an issue
  if (( $(echo "$count_val > $WARNINGS_THRESHOLD" | bc -l) )); then
    # Adjust severity based on error type - these are active issues affecting API operations
    case "$error_type" in
      "BackendServiceUnreachable"|"BackendOperationTimedOut")
        severity="2"  # Major - backend connectivity issues
        ;;
      "JwtValidationFailed"|"InvalidCertificate")
        severity="3"  # Error - authentication/security issues
        ;;
      *)
        severity="3"  # Error - other operational issues
        ;;
    esac

    issues_json=$(echo "$issues_json" | jq \
      --arg t "Frequent APIM \`$error_type\` Errors in \`$category\` for \`$APIM_NAME\`" \
      --arg d "$count_val occurrences in last $TIME_RANGE (Category: $category). Azure Portal: $PORTAL_URL" \
      --arg s "$severity" \
      --arg n "Investigate \`$error_type\` root cause for APIM \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\`. Check backend services and APIM configuration" \
      --arg observed_at "$observed_at" \
      --arg portal "$PORTAL_URL" \
      '.issues += [{
         "title": $t,
         "details": $d,
         "next_steps": $n,
         "observed_at": $observed_at,
         "portal_url": $portal,
         "severity": ($s | tonumber)
       }]')
  fi
done

# If none of the known errors were found, we might do an Additional check for "OtherError"
# or just remain silent. The script won't produce an issue if everything's below threshold.

###############################################################################
# 9) Final JSON with portal URL
###############################################################################
final_json="$(jq -n \
  --argjson i "$(echo "$issues_json" | jq '.issues')" \
  --arg portal "$PORTAL_URL" \
  '{ "issues": $i, "portal_url": $portal }'
)"

echo "$final_json" > "$OUTPUT_FILE"
echo "[INFO] Enhanced APIM log check done. Results -> $OUTPUT_FILE"
echo "[INFO] Azure Portal: $PORTAL_URL"
