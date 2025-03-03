#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   APP_GATEWAY_NAME
#   AZ_RESOURCE_GROUP
#
# OPTIONAL ENV VARS:
#   WARNINGS_THRESHOLD: Integer threshold for matching warnings (default=1)
#   TIME_RANGE:         Kusto time window to look back (default=PT1H)
#   OUTPUT_DIR:         Where to store the resulting JSON (default=./output)
#
# This script:
#   1) Retrieves the Application Gateway Resource ID by name/RG
#   2) Checks if there's a Diagnostic Setting that sends logs to a Log Analytics workspace
#   3) If so, retrieves that workspace's GUID
#   4) Queries known warnings (like "IP configuration mismatch" / "Subnet not found")
#   5) Raises an issue if warnings exceed threshold
#   6) Saves final JSON to appgw_diagnostic_issues.json
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

WARNINGS_THRESHOLD="${WARNINGS_THRESHOLD:-1}"
TIME_RANGE="${TIME_RANGE:-1h}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_FILE="${OUTPUT_DIR}/appgw_diagnostic_log_issues.json"

issues_json='{"issues": []}'

echo "Analyzing App Gateway Diagnostic Logs..."
echo "App Gateway Name: $APP_GATEWAY_NAME"
echo "Resource Group:   $AZ_RESOURCE_GROUP"
echo "Time Range:       $TIME_RANGE"
echo "Warnings Threshold: $WARNINGS_THRESHOLD"

# -----------------------------------------------------------------------------
# 1) Derive the AGW resource ID from name + resource group
# -----------------------------------------------------------------------------
AGW_RESOURCE_ID=""
echo "Retrieving the App Gateway resource ID..."
if ! AGW_RESOURCE_ID=$(az network application-gateway show \
      --name "$APP_GATEWAY_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --query "id" -o tsv 2>$OUTPUT_DIR/agw_show_err.log); then
  err_msg=$(cat $OUTPUT_DIR/agw_show_err.log)
  rm -f $OUTPUT_DIR/agw_show_err.log

  echo "ERROR: Could not fetch App Gateway resource ID."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Failed to Retrieve App Gateway Resource ID" \
    --arg details "$err_msg" \
    --arg severity "1" \
    --arg nextStep "Check if the name and resource group are correct, or if you have the right CLI permissions." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f $OUTPUT_DIR/agw_show_err.log

if [[ -z "$AGW_RESOURCE_ID" ]]; then
  echo "No resource ID returned. Possibly the App Gateway doesn't exist in that RG."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "App Gateway Resource Not Found" \
    --arg details "az network application-gateway show returned empty ID." \
    --arg severity "1" \
    --arg nextStep "Check the name and resource group or create the App Gateway." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
    }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi

echo "App Gateway Resource ID: $AGW_RESOURCE_ID"

# -----------------------------------------------------------------------------
# 2) Check Diagnostic Settings to see if logs are sent to a Log Analytics workspace
# -----------------------------------------------------------------------------
echo "Checking diagnostic settings for resource: $AGW_RESOURCE_ID"
diag_settings_json=$(az monitor diagnostic-settings list --resource "$AGW_RESOURCE_ID" -o json 2>$OUTPUT_DIR/diag_err.log || true)

if [[ -z "$diag_settings_json" || "$diag_settings_json" == "[]" ]]; then
  echo "No diagnostic settings found for App Gateway resource."
  err_msg=$(cat $OUTPUT_DIR/diag_err.log)
  rm -f $OUTPUT_DIR/diag_err.log

  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Diagnostic Settings Found" \
    --arg details "No diagnostic settings send logs to Log Analytics. $err_msg" \
    --arg severity "4" \
    --arg nextStep "Configure a diagnostic setting to forward for Application Gateway \`$APP_GATEWAY_NAME\` logs to Log Analytics in in Resource Group \`$AZ_RESOURCE_GROUP\`" \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi
rm -f $OUTPUT_DIR/diag_err.log

echo "Diagnostic Settings JSON:"
echo "$diag_settings_json" | jq .

# Identify a diag setting with a workspaceId
WS_RESOURCE_ID=$(echo "$diag_settings_json" | jq -r '.[] | select(.workspaceId != null) | .workspaceId' | head -n 1)
if [[ -z "$WS_RESOURCE_ID" || "$WS_RESOURCE_ID" == "null" ]]; then
  echo "No Log Analytics workspace found in these diagnostic settings."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Log Analytics Workspace Setting" \
    --arg details "None of the diagnostic settings route logs to a Log Analytics workspace." \
    --arg severity "1" \
    --arg nextStep "Configure at least one setting to send logs to Log Analytics to enable log queries for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`" \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 0
fi

echo "Found workspace resource ID: $WS_RESOURCE_ID"

# 3) Convert the workspace resource ID into a Log Analytics GUID
echo "Retrieving Log Analytics Workspace GUID..."
if ! WORKSPACE_ID=$(az monitor log-analytics workspace show \
      --ids "$WS_RESOURCE_ID" \
      --query "customerId" -o tsv 2>$OUTPUT_DIR/la_guid_err.log); then
  err_msg=$(cat $OUTPUT_DIR/la_guid_err.log)
  rm -f $OUTPUT_DIR/la_guid_err.log
  echo "ERROR: Could not retrieve workspace GUID."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Failed to Get Workspace GUID" \
    --arg details "$err_msg" \
    --arg severity "1" \
    --arg nextStep "Check if you have Reader or higher role on the workspace resource. Also verify it is a valid workspace ID." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f $OUTPUT_DIR/la_guid_err.log

echo "Using Workspace GUID: $WORKSPACE_ID"

# -----------------------------------------------------------------------------
# 4) Construct the Kusto query for known warnings
# -----------------------------------------------------------------------------
KUSTO_QUERY=$(cat <<EOF
AzureDiagnostics
| where TimeGenerated >= ago(${TIME_RANGE})
| where Category == "ApplicationGatewayPlatformLogs"
| where ResourceId == "${AGW_RESOURCE_ID}"
| where message has "IP configuration mismatch" or message has "Subnet not found"
| summarize CountOfMatches = count()
EOF
)

echo "Kusto Query:"
echo "$KUSTO_QUERY"

# -----------------------------------------------------------------------------
# 5) Run the log query
# -----------------------------------------------------------------------------
if ! query_output=$(az monitor log-analytics query \
      --workspace "$WORKSPACE_ID" \
      --analytics-query "$KUSTO_QUERY" \
      -o json 2>$OUTPUT_DIR/la_query_err.log); then
  err_msg=$(cat $OUTPUT_DIR/la_query_err.log)
  rm -f $OUTPUT_DIR/la_query_err.log
  echo "ERROR: 'az monitor log-analytics query' command failed."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Failed Log Analytics Query" \
    --arg details "$err_msg" \
    --arg severity "1" \
    --arg nextStep "Verify query syntax, aggregator, or ensure the workspace has logs." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  exit 1
fi
rm -f $OUTPUT_DIR/la_query_err.log

echo "Raw query output:"
echo "$query_output"

# Parse the summarized count
count_of_matches=$(echo "$query_output" | jq -r '.tables[0].rows[0][0] // 0' 2>/dev/null || echo "0")
echo "Count of matched warnings in last $TIME_RANGE: $count_of_matches"

# -----------------------------------------------------------------------------
# 6) Compare with threshold
# -----------------------------------------------------------------------------
if (( $(echo "$count_of_matches > $WARNINGS_THRESHOLD" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Frequent App Gateway Diagnostic Warnings Found" \
    --arg details "Found $count_of_matches log entries matching 'IP config mismatch' or 'Subnet not found' in $TIME_RANGE." \
    --arg severity "2" \
    --arg nextStep "Investigate network config or subnet issues for for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`" \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
else
  echo "No repeated warnings found above threshold ($WARNINGS_THRESHOLD)."
fi

# -----------------------------------------------------------------------------
# 7) Write final JSON
# -----------------------------------------------------------------------------
echo "$issues_json" > "$OUTPUT_FILE"
echo "Diagnostic log check completed. Saved results to $OUTPUT_FILE"
