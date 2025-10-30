#!/bin/bash

# ENV:
# FUNCTION_APP_NAME
# AZ_RESOURCE_GROUP
# RW_LOOKBACK_WINDOW (Optional, default is 60)
# AZURE_RESOURCE_SUBSCRIPTION_ID (Optional, defaults to current subscription)

# Set the default time period to 120 minutes if not provided
RW_LOOKBACK_WINDOW="${RW_LOOKBACK_WINDOW:-120}"

# Calculate the start and end times
start_time=$(date -u -d "$RW_LOOKBACK_WINDOW minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Get subscription name from environment variable
subscription_name="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Remove previous issues JSON file if it exists
[ -f "function_app_activities_issues.json" ] && rm "function_app_activities_issues.json"

# Validate required environment variables
if [[ -z "$FUNCTION_APP_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
  echo "Error: FUNCTION_APP_NAME and AZ_RESOURCE_GROUP must be set."
  exit 1
fi

echo "Azure Function App '$FUNCTION_APP_NAME' activity logs (recent):"

# Retrieve the resource ID of the Function App
resource_id=$(az functionapp show \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "id" -o tsv 2>/dev/null)

# Check if resource ID was found
if [[ -z "$resource_id" ]]; then
    echo "Error: Function App '$FUNCTION_APP_NAME' not found in resource group '$AZ_RESOURCE_GROUP'."
    exit 1
fi

# Initialize the JSON object to store issues only - this ensures we always have valid output
issues_json=$(jq -n '{issues: []}')

# Check the status of the Function App
function_app_state=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv 2>/dev/null)

if [[ "$function_app_state" != "Running" ]]; then
    echo "CRITICAL: Function App $FUNCTION_APP_NAME is $function_app_state (not running)!"
    portal_url="https://portal.azure.com/#@/resource${resource_id}/overview"
    
    # Build a link for the Azure Portal event logs (optional convenience)
    tenant_id=$(az account show --query "tenantId" -o tsv)
    subscription_id=$(az account show --query "id" -o tsv)
    event_log_url="https://portal.azure.com/#@$tenant_id/resource/subscriptions/$subscription_id/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME/eventlogs"
    
    # Add critical issue for stopped service
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` is $function_app_state (Not Running)" \
        --arg nextStep "Function App \`$FUNCTION_APP_NAME\` is currently $function_app_state. Check the service status and recent activities to determine why it stopped." \
        --arg severity "1" \
        --arg details "Function App state: $function_app_state. Resource ID: $resource_id. Portal URL: $portal_url | Activity Log: $event_log_url" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
    )
fi

# List activity logs for the Function App
az monitor activity-log list \
  --resource-id "$resource_id" \
  --start-time "$start_time" \
  --end-time "$end_time" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --output table

# Continue with activity analysis

# Define log levels with a severity mapping for your tasks
declare -A log_levels=( ["Critical"]="1" ["Error"]="2" ["Warning"]="4" )

# Define critical operations that should be flagged
critical_operations=("stop" "restart" "start" "delete" "write")

# Loop through each log level and gather events
for level in "${!log_levels[@]}"; do
    # Query activity logs matching this level
    details=$(
      az monitor activity-log list \
        --resource-id "$resource_id" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --resource-group "$AZ_RESOURCE_GROUP" \
        --query "[?level=='$level']" \
        -o json | \
      jq -c "[.[] | {
          eventTimestamp,
          caller,
          level,
          status: .status.value,
          action: .authorization.action,
          resourceId,
          resourceGroupName,
          operationName: .operationName.localizedValue,
          resourceProvider: .resourceProviderName.localizedValue,
          message: .properties.message,
          correlationId,
          claims: {
              email: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress\",
              givenname: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname\",
              surname: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname\",
              ipaddr: .claims.ipaddr
          }
      }]"
    )

    # If we found logs for this level, add them as an "issue" in the JSON
    if [[ $(echo "$details" | jq length) -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "$level level issues detected for Azure Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
            --arg nextStep "Review the $level-level activity logs for Azure Function App \`$FUNCTION_APP_NAME\`." \
            --arg severity "${log_levels[$level]}" \
            --arg eventLogUrl "$event_log_url" \
            --argjson logs "$details" \
            '.issues += [{
                "title": $title,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "details": ($logs + [{"activity_log_url": $eventLogUrl}])
            }]'
        )
    fi
done

# Enhanced Activity Monitoring - Check for critical operations
echo "Checking for critical operations (stop, start, restart, delete, write)..."

# First, let's do a broad search for any operations that might be related to stopping
echo "DEBUG: Searching for any operations that might indicate stopping..."
echo "DEBUG: Looking for operations in the last 2 hours to capture stop events..."

# Extend search window to 2 hours for stop operations
extended_start_time=$(date -u -d "120 minutes ago" '+%Y-%m-%dT%H:%M:%SZ')

# Search for stop-related operations with broader terms
stop_related_terms=("stop" "Stop" "shutdown" "disable" "turned" "offline")

for term in "${stop_related_terms[@]}"; do
    echo "DEBUG: Searching for operations containing '$term'..."
    
    stop_search=$(az monitor activity-log list \
        --resource-id "$resource_id" \
        --start-time "$extended_start_time" \
        --end-time "$end_time" \
        --resource-group "$AZ_RESOURCE_GROUP" \
        --query "[?contains(operationName.value, '$term') || contains(operationName.localizedValue, '$term')]" \
        -o json 2>/dev/null)
    
    if [[ $(echo "$stop_search" | jq length) -gt 0 ]]; then
        echo "DEBUG: Found $(echo "$stop_search" | jq length) operations containing '$term'"
        echo "$stop_search" | jq -r '.[] | "  - \(.eventTimestamp) | \(.caller) | \(.operationName.value) | \(.status.value)"'
    fi
done

# Also search at subscription level for Function App operations
echo "DEBUG: Searching subscription-level logs for Function App operations..."
subscription_stop_search=$(az monitor activity-log list \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    --query "[?contains(resourceId, '$FUNCTION_APP_NAME') && (contains(operationName.value, 'stop') || contains(operationName.value, 'Stop'))]" \
    -o json 2>/dev/null)

if [[ $(echo "$subscription_stop_search" | jq length) -gt 0 ]]; then
    echo "DEBUG: Found $(echo "$subscription_stop_search" | jq length) subscription-level stop operations"
    echo "$subscription_stop_search" | jq -r '.[] | "  - \(.eventTimestamp) | \(.caller) | \(.operationName.value) | \(.status.value)"'
fi

for operation in "${critical_operations[@]}"; do
    echo "Searching for '$operation' operations..."
    
    # Use dynamic query construction to avoid variable expansion issues
    query_filter="[?contains(operationName.value, '$operation')]"
    
    critical_activities=$(
        az monitor activity-log list \
            --resource-id "$resource_id" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --resource-group "$AZ_RESOURCE_GROUP" \
            --query "$query_filter" \
            -o json | \
        jq -c "[.[] | {
            eventTimestamp,
            caller,
            level,
            status: .status.value,
            action: .authorization.action,
            resourceId,
            resourceGroupName,
            operationName: .operationName.value,
            resourceProvider: .resourceProviderName.value,
            message: .properties.message,
            correlationId,
            claims: {
                email: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress\",
                givenname: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname\",
                surname: .claims.\"http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname\",
                ipaddr: .claims.ipaddr
            }
        }]"
    )
    
    # If we found critical activities, add them as issues
    if [[ $(echo "$critical_activities" | jq length) -gt 0 ]]; then
        # Extract user information for title
        user_info=$(echo "$critical_activities" | jq -r '.[0].claims.email // .[0].caller // "Unknown User"')
        user_name=$(echo "$critical_activities" | jq -r '.[0].claims.givenname // ""')
        user_surname=$(echo "$critical_activities" | jq -r '.[0].claims.surname // ""')
        user_ip=$(echo "$critical_activities" | jq -r '.[0].claims.ipaddr // ""')
        
        # Build user identification string
        user_details="$user_info"
        if [[ -n "$user_name" && -n "$user_surname" ]]; then
            user_details="$user_name $user_surname ($user_info)"
        fi
        if [[ -n "$user_ip" ]]; then
            user_details="$user_details from IP $user_ip"
        fi
        
        # Determine severity based on operation and current state
        severity="2"
        if [[ "$operation" == "stop" || "$operation" == "delete" ]]; then
            severity="1"
        fi
        
        # Add correlation with current service state
        correlation_note=""
        if [[ "$function_app_state" != "Running" && "$operation" == "stop" ]]; then
            correlation_note=" **CORRELATION**: Function App is currently $function_app_state, which correlates with this $operation operation."
        fi
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Critical '$operation' Operation on Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` by $user_details" \
            --arg nextStep "Review the '$operation' operation performed on Function App \`$FUNCTION_APP_NAME\` by $user_details. Check if this was intentional and if the service should be restored.$correlation_note" \
            --arg severity "$severity" \
            --arg eventLogUrl "$event_log_url" \
            --argjson activities "$critical_activities" \
            '.issues += [{
                "title": $title,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "details": ($activities + [{"activity_log_url": $eventLogUrl, "portal_url": "https://portal.azure.com/#@/resource'$resource_id'/overview"}])
            }]'
        )
        
        echo "Found $operation operations by $user_details"
    fi
done

# Additional analysis for stopped Function Apps
if [[ "$function_app_state" != "Running" ]]; then
    echo "DEBUG: Function App is $function_app_state. Performing extended search for stop operations..."
    
    # Search for any operations (not just stop) in the last 7 days to determine when it was last active
    extended_7d_start=$(date -u -d "7 days ago" '+%Y-%m-%dT%H:%M:%SZ')
    
    non_publishxml_operations=$(az monitor activity-log list \
        --resource-id "$resource_id" \
        --start-time "$extended_7d_start" \
        --end-time "$end_time" \
        --query "[?operationName.value != 'Microsoft.Web/sites/publishxml/action']" \
        -o json | jq -c '.')
    
    operation_count=$(echo "$non_publishxml_operations" | jq length)
    
    if [[ $operation_count -eq 0 ]]; then
        echo "DEBUG: No non-publishxml operations found in the last 7 days"
        
        # Add informational issue about long-term stopped state
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` Has Been Stopped for Extended Period" \
            --arg nextStep "Function App \`$FUNCTION_APP_NAME\` appears to have been stopped for more than 7 days. No recent stop operations found in activity logs. This may indicate a forgotten manual stop, automated process, or the Function App was created in a stopped state." \
            --arg severity "2" \
            --arg details "No operational activity (excluding publish profile requests) found in the last 7 days. This suggests the Function App was stopped more than 7 days ago. Portal URL: $portal_url" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
        )
        
        echo "Added issue for extended stopped period"
    else
        echo "DEBUG: Found $operation_count non-publishxml operations in the last 7 days"
        echo "$non_publishxml_operations" | jq -r '.[] | "\(.eventTimestamp) | \(.caller) | \(.operationName.value) | \(.status.value)"' | head -3
    fi
fi

# Save the results
echo "$issues_json" > "function_app_activities_issues.json"
echo "Done. Any issues found are in 'function_app_activities_issues.json'."
