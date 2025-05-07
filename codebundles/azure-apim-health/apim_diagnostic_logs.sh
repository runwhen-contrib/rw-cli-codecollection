#!/usr/bin/env bash
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

set -euo pipefail

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

echo "[INFO] Gathering APIM Diagnostics & Logs (enhanced known errors)..."
echo " APIM Name:     $APIM_NAME"
echo " ResourceGroup: $AZ_RESOURCE_GROUP"
echo " Time Range:    $TIME_RANGE"
echo " Threshold:     $WARNINGS_THRESHOLD"

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
    --arg t "Failed to Retrieve APIM Resource ID" \
    --arg d "$err_msg" \
    --arg s "1" \
    --arg n "Check APIM name/RG and permissions." \
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
    --arg t "APIM Resource Not Found" \
    --arg d "az apim show returned empty ID." \
    --arg s "1" \
    --arg n "Check name/RG or create APIM." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi

echo "[INFO] APIM Resource ID: $apim_resource_id"

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
    --arg t "No Diagnostic Settings for APIM" \
    --arg d "No diag settings route logs to Log Analytics. $err_msg" \
    --arg s "4" \
    --arg n "Configure at least one diag setting for APIM logs => Log Analytics." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
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
    --arg t "No LA Workspace Configured" \
    --arg d "Diag settings exist but none route to a workspace." \
    --arg s "1" \
    --arg n "Enable a diag setting with a workspace to query APIM logs." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
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
    --arg t "Failed to Retrieve Workspace GUID" \
    --arg d "$err_msg" \
    --arg s "1" \
    --arg n "Check roles or validity of workspace ID." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f la_guid_err.log
echo "[INFO] Workspace GUID: $workspace_id"

###############################################################################
# 5) Enhanced Kusto Query for known APIM errors/warnings
#    We label each error with KnownErrorType via a 'case' expression:
#      - 'Backend service unreachable'
#      - 'JWT validation failed'
#      - 'Operation timed out'
#      - 'Invalid certificate'
#      - fallback => 'OtherError'
###############################################################################
KUSTO_QUERY=$(cat <<EOF
AzureDiagnostics
| where TimeGenerated >= ago(${TIME_RANGE})
| where Category in ("GatewayLogs", "AuditLogs")
| where ResourceId == "${apim_resource_id}"
| where Level in ("Error","Warning")
| extend KnownErrorType = case(
    Message has "Backend service unreachable","BackendServiceUnreachable",
    Message has "JWT validation failed","JwtValidationFailed",
    Message has "operation timed out","BackendOperationTimedOut",
    Message has "invalid certificate","InvalidCertificate",
    "OtherError"
)
| summarize CountOfMatches = count() by KnownErrorType
EOF
)

echo "[INFO] Kusto Query for known APIM errors:"
echo "$KUSTO_QUERY"

###############################################################################
# 6) Run the log query
###############################################################################
if ! query_output=$(az monitor log-analytics query \
      --workspace "$workspace_id" \
      --analytics-query "$KUSTO_QUERY" \
      -o json 2>la_query_err.log); then
  err_msg=$(cat la_query_err.log)
  rm -f la_query_err.log
  echo "ERROR: Log Analytics query failed."
  issues_json=$(echo "$issues_json" | jq \
    --arg t "Failed APIM Log Analytics Query" \
    --arg d "$err_msg" \
    --arg s "1" \
    --arg n "Check query syntax or ensure logs appear in the workspace." \
    '.issues += [{
       "title": $t,
       "details": $d,
       "next_steps": $n,
       "severity": ($s | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f la_query_err.log

echo "[INFO] Raw query output:"
echo "$query_output"

###############################################################################
# 7) Parse each KnownErrorType row => [ KnownErrorType, CountOfMatches ]
#    We'll create an issue if CountOfMatches > WARNINGS_THRESHOLD
###############################################################################
rows_len=$(echo "$query_output" | jq -r '.tables[0].rows | length')
if [[ "$rows_len" == "null" ]]; then
  rows_len=0
fi

for (( i=0; i<rows_len; i++ )); do
  error_type=$(echo "$query_output" | jq -r ".tables[0].rows[$i][0] // \"UnknownError\"")
  count_val=$(echo "$query_output" | jq -r ".tables[0].rows[$i][1] // 0")
  echo "[INFO] Found error type '$error_type' => count=$count_val"

  # If count_val > threshold => log an issue
  if (( $(echo "$count_val > $WARNINGS_THRESHOLD" | bc -l) )); then
    # Adjust severity as needed
    severity="2"
    # If you want different thresholds or severities per error_type, handle that here

    issues_json=$(echo "$issues_json" | jq \
      --arg t "Frequent APIM $error_type" \
      --arg d "$count_val occurrences in last $TIME_RANGE" \
      --arg s "$severity" \
      --arg n "Investigate $error_type root cause for APIM '$APIM_NAME' in RG '$AZ_RESOURCE_GROUP'." \
      '.issues += [{
         "title": $t,
         "details": $d,
         "next_steps": $n,
         "severity": ($s | tonumber)
       }]')
  fi
done

# If none of the known errors were found, we might do an Additional check for "OtherError"
# or just remain silent. The script won't produce an issue if everything's below threshold.

###############################################################################
# 8) Final JSON => apim_diagnostic_log_issues.json
###############################################################################
echo "$issues_json" > "$OUTPUT_FILE"
echo "[INFO] Enhanced APIM log check done. Results -> $OUTPUT_FILE"
