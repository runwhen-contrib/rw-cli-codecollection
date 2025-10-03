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

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

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
  -o json 2>/dev/null | jq -r '.tables[0].rows[]?[0]? // empty' | sort -u)

echo "[INFO] Available log categories: $available_categories"

# Build category list for query
category_list="GatewayLogs"
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
| summarize CountOfMatches = count() by KnownErrorType, Category
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
rows_len=$(echo "$query_output" | jq -r '.tables[0].rows | length')
if [[ "$rows_len" == "null" ]]; then
  rows_len=0
fi

for (( i=0; i<rows_len; i++ )); do
  error_type=$(echo "$query_output" | jq -r ".tables[0].rows[$i][0] // \"UnknownError\"")
  count_val=$(echo "$query_output" | jq -r ".tables[0].rows[$i][1] // 0")
  category=$(echo "$query_output" | jq -r ".tables[0].rows[$i][2] // \"Unknown\"")
  echo "[INFO] Found error type \`$error_type\` in \`$category\` => count=$count_val"

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
      --arg portal "$PORTAL_URL" \
      '.issues += [{
         "title": $t,
         "details": $d,
         "next_steps": $n,
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
