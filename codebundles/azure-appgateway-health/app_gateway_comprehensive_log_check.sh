#!/usr/bin/env bash
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

set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   APP_GATEWAY_NAME
#   AZ_RESOURCE_GROUP
#
# OPTIONAL ENV VARS:
#   HTTP_ERROR_THRESHOLD: Integer threshold for HTTP error count (default=10)
#   FIREWALL_BLOCK_THRESHOLD: Integer threshold for firewall blocks (default=5)
#   TIME_RANGE:         Kusto time window to look back (default=1h)
#
# This script:
#   1) Retrieves the Application Gateway Resource ID by name/RG
#   2) Checks if there's a Diagnostic Setting that sends logs to a Log Analytics workspace
#   3) If so, retrieves that workspace's GUID
#   4) Queries multiple types of issues:
#      - HTTP error responses (4xx/5xx status codes)
#      - Firewall blocks (if WAF is enabled)
#      - Performance issues (if performance logs are enabled)
#   5) Raises issues if any thresholds are exceeded
#   6) Saves final JSON to appgw_comprehensive_issues.json
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

HTTP_ERROR_THRESHOLD="${HTTP_ERROR_THRESHOLD:-10}"
FIREWALL_BLOCK_THRESHOLD="${FIREWALL_BLOCK_THRESHOLD:-5}"
TIME_RANGE="${TIME_RANGE:-1h}"
OUTPUT_FILE="appgw_comprehensive_issues.json"

issues_json='{"issues": []}'

echo "Comprehensive App Gateway Log Analysis..."
echo "App Gateway Name: $APP_GATEWAY_NAME"
echo "Resource Group:   $AZ_RESOURCE_GROUP"
echo "Time Range:       $TIME_RANGE"
echo "HTTP Error Threshold: $HTTP_ERROR_THRESHOLD"
echo "Firewall Block Threshold: $FIREWALL_BLOCK_THRESHOLD"

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
    --arg nextStep "Configure a diagnostic setting to forward Application Gateway \`$APP_GATEWAY_NAME\` logs to Log Analytics in Resource Group \`$AZ_RESOURCE_GROUP\`" \
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

# Helper function to safely run a query and return "0" if there's an error/no data
function run_query() {
  local query="$1"
  local result

  if ! result=$(az monitor log-analytics query \
      --workspace "$WORKSPACE_ID" \
      --analytics-query "$query" \
      -o json 2>/dev/null); then
    echo "0"
    return
  fi

  echo "$result" | jq -r '.tables[0].rows[0][0] // 0' 2>/dev/null || echo "0"
}

# -----------------------------------------------------------------------------
# 4) Check HTTP Error Rates
# -----------------------------------------------------------------------------
echo "Checking HTTP error rates..."
HTTP_ERROR_QUERY=$(cat <<EOF
AzureDiagnostics
| where TimeGenerated >= ago(${TIME_RANGE})
| where Category == "ApplicationGatewayAccessLog"
| where ResourceId == "${AGW_RESOURCE_ID}"
| where toint(httpStatus_d) >= 400 and toint(httpStatus_d) < 600
| summarize CountOfErrors = count()
EOF
)

http_error_count=$(run_query "$HTTP_ERROR_QUERY")
echo "HTTP error count in last $TIME_RANGE: $http_error_count"

if (( $(echo "$http_error_count > $HTTP_ERROR_THRESHOLD" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High HTTP Error Rate Detected" \
    --arg details "Found $http_error_count HTTP error responses (4xx/5xx status codes) in $TIME_RANGE, exceeding threshold of $HTTP_ERROR_THRESHOLD." \
    --arg severity "2" \
    --arg nextStep "Investigate the cause of HTTP errors for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`. Check backend health, SSL certificates, and routing rules." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
fi

# -----------------------------------------------------------------------------
# 5) Check Firewall Blocks (if WAF is enabled)
# -----------------------------------------------------------------------------
echo "Checking firewall blocks..."
FIREWALL_QUERY=$(cat <<EOF
AzureDiagnostics
| where TimeGenerated >= ago(${TIME_RANGE})
| where Category == "ApplicationGatewayFirewallLog"
| where ResourceId == "${AGW_RESOURCE_ID}"
| where action_s == "Blocked"
| summarize CountOfBlocks = count()
EOF
)

firewall_block_count=$(run_query "$FIREWALL_QUERY")
echo "Firewall block count in last $TIME_RANGE: $firewall_block_count"

if (( $(echo "$firewall_block_count > $FIREWALL_BLOCK_THRESHOLD" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High Firewall Block Rate Detected" \
    --arg details "Found $firewall_block_count firewall blocks in $TIME_RANGE, exceeding threshold of $FIREWALL_BLOCK_THRESHOLD." \
    --arg severity "3" \
    --arg nextStep "Review WAF rules and blocked requests for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`. Consider adjusting WAF policies if legitimate traffic is being blocked." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
fi

# -----------------------------------------------------------------------------
# 6) Check for any critical errors in performance logs
# -----------------------------------------------------------------------------
echo "Checking performance logs for errors..."
PERFORMANCE_ERROR_QUERY=$(cat <<EOF
AzureDiagnostics
| where TimeGenerated >= ago(${TIME_RANGE})
| where Category == "ApplicationGatewayPerformanceLog"
| where ResourceId == "${AGW_RESOURCE_ID}"
| summarize CountOfErrors = count()
EOF
)

performance_error_count=$(run_query "$PERFORMANCE_ERROR_QUERY")
echo "Performance log entries in last $TIME_RANGE: $performance_error_count"

# Note: Performance logs don't have standardized error fields, so we just count entries
# This can be used to verify that performance logging is working
if (( $(echo "$performance_error_count == 0" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Performance Logs Found" \
    --arg details "No performance log entries found in $TIME_RANGE. This may indicate that performance logging is not properly configured or there are no requests." \
    --arg severity "4" \
    --arg nextStep "Verify that ApplicationGatewayPerformanceLog is enabled in diagnostic settings for Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
     }]')
fi

# -----------------------------------------------------------------------------
# 7) Write final JSON
# -----------------------------------------------------------------------------
echo "$issues_json" > "$OUTPUT_FILE"
echo "Comprehensive log analysis completed. Saved results to $OUTPUT_FILE"

# Print summary
echo "-------------------------------------------------"
echo "Summary:"
echo "HTTP Errors: $http_error_count (threshold: $HTTP_ERROR_THRESHOLD)"
echo "Firewall Blocks: $firewall_block_count (threshold: $FIREWALL_BLOCK_THRESHOLD)"
echo "Performance Log Entries: $performance_error_count"
echo "Total Issues Found: $(echo "$issues_json" | jq '.issues | length')"
echo "-------------------------------------------------" 