#!/bin/bash
# Script to check Azure Activity Logs for APIM management operations
# Focuses on administrative issues that might affect functionality

set -eo pipefail

: "${APIM_NAME:?Environment variable APIM_NAME must be set}"
: "${AZ_RESOURCE_GROUP:?Environment variable AZ_RESOURCE_GROUP must be set}"
: "${TIME_PERIOD_MINUTES:?Environment variable TIME_PERIOD_MINUTES must be set}"

OUTPUT_FILE="apim_activity_log_issues.json"
issues_json='{"issues": []}'

echo "[INFO] Checking Activity Logs for APIM \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\` (last $TIME_PERIOD_MINUTES minutes)..."

###############################################################################
# Set subscription context if provided
###############################################################################
if [[ -n "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    echo "[INFO] Setting subscription context to: $AZURE_RESOURCE_SUBSCRIPTION_ID"
    az account set --subscription "$AZURE_RESOURCE_SUBSCRIPTION_ID" || {
        echo "ERROR: Failed to set subscription context"
        exit 1
    }
fi

###############################################################################
# Get APIM resource information and construct portal URL
###############################################################################
echo "[INFO] Getting APIM resource information..."
if ! apim_resource_id=$(az apim show \
        --name "$APIM_NAME" \
        --resource-group "$AZ_RESOURCE_GROUP" \
        --query "id" -o tsv 2>apim_err.log); then
    err_msg=$(cat apim_err.log)
    rm -f apim_err.log
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
rm -f apim_err.log

if [[ -z "$apim_resource_id" ]]; then
    echo "No resource ID returned. Possibly the APIM doesn't exist."
    issues_json=$(echo "$issues_json" | jq \
        --arg t "APIM Resource \`$APIM_NAME\` Not Found" \
        --arg d "az apim show returned empty ID. Azure Portal: https://portal.azure.com" \
        --arg s "1" \
        --arg n "Check APIM name \`$APIM_NAME\` and RG \`$AZ_RESOURCE_GROUP\` or create APIM instance" \
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
# 3) Calculate time range for activity log query
###############################################################################
end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "[INFO] Querying activity logs from $start_time to $end_time"

###############################################################################
# 4) Query Activity Logs for the APIM resource
###############################################################################
echo "[INFO] Retrieving activity logs for APIM resource..."
if ! activity_logs=$(az monitor activity-log list \
      --resource-id "$apim_resource_id" \
      --start-time "$start_time" \
      --end-time "$end_time" \
      -o json 2>activity_err.log); then
    err_msg=$(cat activity_err.log)
    rm -f activity_err.log
    echo "ERROR: Failed to retrieve activity logs."
    issues_json=$(echo "$issues_json" | jq \
        --arg t "Failed to Query Activity Logs for APIM \`$APIM_NAME\`" \
        --arg d "$err_msg. Azure Portal: $PORTAL_URL" \
        --arg s "1" \
        --arg n "Check permissions for reading activity logs for RG \`$AZ_RESOURCE_GROUP\`" \
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
rm -f activity_err.log

###############################################################################
# 5) Parse and analyze activity log entries
###############################################################################
if [[ "$activity_logs" == "[]" || -z "$activity_logs" ]]; then
    echo "[INFO] No activity log entries found for the specified time period."
    final_json="$(jq -n \
      --argjson i "$(echo "$issues_json" | jq '.issues')" \
      --arg portal "$PORTAL_URL" \
      '{ "issues": $i, "portal_url": $portal }'
    )"
    echo "$final_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "[INFO] Found activity log entries. Analyzing..."

# Count and categorize different types of activities
failed_operations=$(echo "$activity_logs" | jq '[.[] | select(.status.value == "Failed")] | length')
error_operations=$(echo "$activity_logs" | jq '[.[] | select(.level == "Error")] | length')
warning_operations=$(echo "$activity_logs" | jq '[.[] | select(.level == "Warning")] | length')
critical_operations=$(echo "$activity_logs" | jq '[.[] | select(.level == "Critical")] | length')

# Check for configuration changes
config_changes=$(echo "$activity_logs" | jq '[.[] | select(.operationName.localizedValue | test("Update|Create|Delete"; "i"))] | length')

echo "[INFO] Activity Log Summary:"
echo "  - Failed Operations: $failed_operations"
echo "  - Error Level: $error_operations"
echo "  - Warning Level: $warning_operations"
echo "  - Critical Level: $critical_operations"
echo "  - Configuration Changes: $config_changes"

###############################################################################
# 6) Generate issues based on findings
###############################################################################

# Critical level operations
if [[ "$critical_operations" -gt 0 ]]; then
    critical_details=$(echo "$activity_logs" | jq -c '[.[] | select(.level == "Critical") | {
        eventTimestamp,
        caller,
        operationName: .operationName.localizedValue,
        status: .status.value,
        subStatus: .subStatus.localizedValue,
        resourceProviderName: .resourceProviderName.value
    }]')
    
    issues_json=$(echo "$issues_json" | jq \
        --arg t "Critical Level Operations Detected for APIM \`$APIM_NAME\`" \
        --arg d "$critical_details. Azure Portal: $PORTAL_URL" \
        --arg s "1" \
        --arg n "Review critical operations immediately for APIM \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\`" \
        --arg portal "$PORTAL_URL" \
        '.issues += [{
           "title": $t,
           "details": $d,
           "next_steps": $n,
           "portal_url": $portal,
           "severity": ($s | tonumber)
        }]')
fi

# Failed operations
if [[ "$failed_operations" -gt 0 ]]; then
    failed_details=$(echo "$activity_logs" | jq -c '[.[] | select(.status.value == "Failed") | {
        eventTimestamp,
        caller,
        operationName: .operationName.localizedValue,
        status: .status.value,
        subStatus: .subStatus.localizedValue,
        resourceProviderName: .resourceProviderName.value
    }]')
    
    issues_json=$(echo "$issues_json" | jq \
        --arg t "Failed Operations Detected for APIM \`$APIM_NAME\`" \
        --arg d "$failed_details. Azure Portal: $PORTAL_URL" \
        --arg s "2" \
        --arg n "Investigate failed operations for APIM \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\`. Check user permissions and resource configuration" \
        --arg portal "$PORTAL_URL" \
        '.issues += [{
           "title": $t,
           "details": $d,
           "next_steps": $n,
           "portal_url": $portal,
           "severity": ($s | tonumber)
        }]')
fi

# Error level operations
if [[ "$error_operations" -gt 0 ]]; then
    error_details=$(echo "$activity_logs" | jq -c '[.[] | select(.level == "Error") | {
        eventTimestamp,
        caller,
        operationName: .operationName.localizedValue,
        status: .status.value,
        subStatus: .subStatus.localizedValue,
        resourceProviderName: .resourceProviderName.value
    }]')
    
    issues_json=$(echo "$issues_json" | jq \
        --arg t "Error Level Operations for APIM \`$APIM_NAME\`" \
        --arg d "$error_details. Azure Portal: $PORTAL_URL" \
        --arg s "2" \
        --arg n "Review error-level administrative operations for APIM \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\`" \
        --arg portal "$PORTAL_URL" \
        '.issues += [{
           "title": $t,
           "details": $d,
           "next_steps": $n,
           "portal_url": $portal,
           "severity": ($s | tonumber)
        }]')
fi

# Check for recent configuration changes that might be related to current issues
if [[ "$config_changes" -gt 0 ]]; then
    # During troubleshooting, any recent config changes are relevant
    config_details=$(echo "$activity_logs" | jq -c '[.[] | select(.operationName.localizedValue | test("Update|Create|Delete"; "i")) | {
        eventTimestamp,
        caller,
        operationName: .operationName.localizedValue,
        status: .status.value
    }]')
    
    # Only report if there are many changes (could indicate instability) or failed changes
    failed_config_changes=$(echo "$activity_logs" | jq '[.[] | select(.operationName.localizedValue | test("Update|Create|Delete"; "i")) | select(.status.value == "Failed")] | length')
    
    if [[ "$config_changes" -gt 10 ]] || [[ "$failed_config_changes" -gt 0 ]]; then
        severity="3"
        if [[ "$failed_config_changes" -gt 0 ]]; then
            title="Recent Failed Configuration Changes for APIM \`$APIM_NAME\`"
            next_steps="Review failed configuration changes for APIM \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\`. These may be causing current issues"
        else
            title="High Volume of Recent Configuration Changes for APIM \`$APIM_NAME\`"
            next_steps="Review recent configuration changes for APIM \`$APIM_NAME\` in RG \`$AZ_RESOURCE_GROUP\` that may have introduced current issues"
        fi
        
        issues_json=$(echo "$issues_json" | jq \
            --arg t "$title" \
            --arg d "$config_details. Azure Portal: $PORTAL_URL" \
            --arg s "$severity" \
            --arg n "$next_steps" \
            --arg portal "$PORTAL_URL" \
            '.issues += [{
               "title": $t,
               "details": $d,
               "next_steps": $n,
               "portal_url": $portal,
               "severity": ($s | tonumber)
            }]')
    fi
fi

###############################################################################
# 7) Final JSON output with portal URL
###############################################################################
final_json="$(jq -n \
  --argjson i "$(echo "$issues_json" | jq '.issues')" \
  --arg portal "$PORTAL_URL" \
  '{ "issues": $i, "portal_url": $portal }'
)"

echo "$final_json" > "$OUTPUT_FILE"
echo "[INFO] APIM Activity Log check complete. Results -> $OUTPUT_FILE"
echo "[INFO] Azure Portal: $PORTAL_URL" 