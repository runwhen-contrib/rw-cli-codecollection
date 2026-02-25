#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   APP_GATEWAY_NAME
#   AZ_RESOURCE_GROUP
#
# OPTIONAL ENV VARS:
#   WARNINGS_THRESHOLD: Integer threshold for HTTP error count (default=1)
#   TIME_RANGE:         Kusto time window to look back (default=PT1H)
#
# This script:
#   1) Retrieves the Application Gateway Resource ID by name/RG
#   2) Checks if there's a Diagnostic Setting that sends logs to a Log Analytics workspace
#   3) If so, retrieves that workspace's GUID
#   4) Queries HTTP error responses (4xx/5xx status codes) in the specified time range
#   5) Raises an issue if error count exceeds threshold
#   6) Saves final JSON to appgw_diagnostic_log_issues.json
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

WARNINGS_THRESHOLD="${WARNINGS_THRESHOLD:-1}"
TIME_RANGE="${TIME_RANGE:-1h}"
OUTPUT_FILE="appgw_diagnostic_log_issues.json"

issues_json='{"issues": []}'

echo "Analyzing App Gateway HTTP Error Rates..."
echo "App Gateway Name: $APP_GATEWAY_NAME"
echo "Resource Group:   $AZ_RESOURCE_GROUP"
echo "Time Range:       $TIME_RANGE"
echo "Error Threshold:  $WARNINGS_THRESHOLD"

# -----------------------------------------------------------------------------
# 1) Derive the AGW resource ID from name + resource group
# -----------------------------------------------------------------------------
AGW_RESOURCE_ID=""
echo "Retrieving the App Gateway resource ID..."
if ! AGW_RESOURCE_ID=$(az network application-gateway show \
      --name "$APP_GATEWAY_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --query "id" -o tsv 2>agw_show_err.log); then
  err_msg=$(cat agw_show_err.log)
  rm -f agw_show_err.log

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
rm -f agw_show_err.log

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
diag_settings_json=$(az monitor diagnostic-settings list --resource "$AGW_RESOURCE_ID" -o json 2>diag_err.log || true)

if [[ -z "$diag_settings_json" || "$diag_settings_json" == "[]" ]]; then
  echo "No diagnostic settings found for App Gateway resource."
  err_msg=$(cat diag_err.log)
  rm -f diag_err.log

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
rm -f diag_err.log

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
      --query "customerId" -o tsv 2>la_guid_err.log); then
  err_msg=$(cat la_guid_err.log)
  rm -f la_guid_err.log
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
rm -f la_guid_err.log

echo "Using Workspace GUID: $WORKSPACE_ID"

# -----------------------------------------------------------------------------
# 4) Construct the Kusto query for known warnings
# -----------------------------------------------------------------------------
KUSTO_QUERY=$(cat <<EOF
AzureDiagnostics
| where TimeGenerated >= ago(${TIME_RANGE})
| where Category == "ApplicationGatewayAccessLog"
| where ResourceId == "${AGW_RESOURCE_ID}"
| where toint(httpStatus_d) >= 400 and toint(httpStatus_d) < 600
| summarize CountOfMatches = count(), LastSeen = max(TimeGenerated)
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
      -o json 2>la_query_err.log); then
  err_msg=$(cat la_query_err.log)
  rm -f la_query_err.log
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
rm -f la_query_err.log

echo "Raw query output:"
echo "$query_output"

# Parse the summarized count
count_of_matches=$(echo "$query_output" | jq -r '.tables[0].rows[0][0] // 0' 2>/dev/null || echo "0")
echo "Count of HTTP errors (4xx/5xx) in last $TIME_RANGE: $count_of_matches"

# -----------------------------------------------------------------------------
# 6) Compare with threshold
# -----------------------------------------------------------------------------
if (( $(echo "$count_of_matches > $WARNINGS_THRESHOLD" | bc -l) )); then
  observed_at=$(echo "$query_output" | jq -r '.tables[0].rows[0][1] // "Unknown"' 2>/dev/null || echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High HTTP Error Rate Detected in Application Gateway" \
    --arg details "Found $count_of_matches HTTP error responses (4xx/5xx status codes) in $TIME_RANGE for Application Gateway $APP_GATEWAY_NAME." \
    --arg severity "2" \
    --arg nextStep "Investigate the cause of HTTP errors for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`. Check backend health, SSL certificates, and routing rules." \
    --arg observed_at "$observed_at" \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "observed_at": $observed_at,
       "severity": ($severity | tonumber)
     }]')
else
  echo "No excessive HTTP errors found above threshold ($WARNINGS_THRESHOLD)."
fi

# -----------------------------------------------------------------------------
# 7) Write final JSON
# -----------------------------------------------------------------------------
echo "$issues_json" > "$OUTPUT_FILE"
echo "HTTP error rate check completed. Saved results to $OUTPUT_FILE"
