#!/bin/bash

# ENV:
# FUNCTION_APP_NAME
# AZ_RESOURCE_GROUP
# RW_LOOKBACK_WINDOW (Optional, default is 120)
# AZURE_RESOURCE_SUBSCRIPTION_ID (Optional, defaults to current subscription)

# Set the default time period to 120 minutes if not provided
RW_LOOKBACK_WINDOW="${RW_LOOKBACK_WINDOW:-120}"

# Calculate the start and end times
start_time=$(date -u -d "$RW_LOOKBACK_WINDOW minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Use subscription ID from environment variable
subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Using subscription ID: $subscription"

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

echo "Checking recent activities for Function App '$FUNCTION_APP_NAME' (last $RW_LOOKBACK_WINDOW minutes)..."

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

# Initialize the JSON object to store issues
issues_json=$(jq -n '{issues: []}')

# Check the current state of the Function App
function_app_state=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv 2>/dev/null)
echo "Current Function App state: $function_app_state"

# Build portal URLs
portal_url="https://portal.azure.com/#@/resource${resource_id}/overview"
tenant_id=$(az account show --query "tenantId" -o tsv)
subscription_id=$(az account show --query "id" -o tsv)
event_log_url="https://portal.azure.com/#@$tenant_id/resource/subscriptions/$subscription_id/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME/eventlogs"

# Check for Log Analytics workspace to use server-side filtering
echo "Finding Log Analytics workspace..."
diagnostic_settings=$(az monitor diagnostic-settings list --resource "$resource_id" --query "[].logAnalyticsWorkspaceId" -o tsv 2>/dev/null)

if [[ -n "$diagnostic_settings" && "$diagnostic_settings" != "null" ]]; then
    workspace_id=$(echo "$diagnostic_settings" | head -1 | sed 's|.*/workspaces/||')
    echo "✅ Using Log Analytics workspace: $workspace_id"
    
    # Server-side KQL query for recent activities
    kql_start_time=$(date -u -d "$RW_LOOKBACK_WINDOW minutes ago" '+%Y-%m-%dT%H:%M:%S.000Z')
    
    recent_activities=$(timeout 45 az monitor log-analytics query \
        --workspace "$workspace_id" \
        --analytics-query "
        AzureActivity
        | where ResourceId == '$resource_id'
        | where TimeGenerated >= datetime('$kql_start_time')
        | where OperationNameValue !in ('Microsoft.Web/sites/publishxml/action', 'Microsoft.Web/sites/backup/action', 'Microsoft.Web/sites/backup/read')
        | project eventTimestamp=TimeGenerated, caller=Caller, operationName=pack('value', OperationNameValue), status=pack('value', ActivityStatusValue), claims=Claims
        | order by eventTimestamp desc
        | limit 100" \
        -o json 2>/dev/null || echo "[]")
else
    echo "⚠️  No Log Analytics workspace found - using Activity Log API for short window"
    echo "Querying recent activities (last $RW_LOOKBACK_WINDOW minutes)..."
    recent_activities=$(az monitor activity-log list \
        --resource-id "$resource_id" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --query "[?operationName.value != 'Microsoft.Web/sites/publishxml/action' && operationName.value != 'Microsoft.Web/sites/backup/action' && operationName.value != 'Microsoft.Web/sites/backup/read']" \
        -o json 2>/dev/null)
fi

# Check for critical operations (start, stop, restart) in the recent activities
echo "Analyzing for critical operations..."

# Extract start operations
start_operations=$(echo "$recent_activities" | jq '[.[] | select(.operationName.value != null and (.operationName.value | contains("start") or contains("Start") or contains("Microsoft.Web/sites/start") or contains("Microsoft.Web/sites/start/action")))]')

# Extract stop operations  
stop_operations=$(echo "$recent_activities" | jq '[.[] | select(.operationName.value != null and (.operationName.value | contains("stop") or contains("Stop") or contains("Microsoft.Web/sites/stop") or contains("Microsoft.Web/sites/stop/action")))]')

# Extract restart operations
restart_operations=$(echo "$recent_activities" | jq '[.[] | select(.operationName.value != null and (.operationName.value | contains("restart") or contains("Restart") or contains("Microsoft.Web/sites/restart") or contains("Microsoft.Web/sites/restart/action")))]')

# Extract failed sync operations (only report if they fail)
sync_operations=$(echo "$recent_activities" | jq '[.[] | select(.operationName.value != null and (.operationName.value | contains("host/sync") or contains("host/sync/action")) and .status.value == "Failed")]')

# Process start operations
if [[ $(echo "$start_operations" | jq length) -gt 0 ]]; then
    echo "Found $(echo "$start_operations" | jq length) start operations"
    
    # Get the most recent start operation
    latest_start=$(echo "$start_operations" | jq 'sort_by(.eventTimestamp) | last')
    
    # Extract user information
    user_info=$(echo "$latest_start" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" // .caller // "Unknown User"')
    user_name=$(echo "$latest_start" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname" // ""')
    user_surname=$(echo "$latest_start" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname" // ""')
    user_ip=$(echo "$latest_start" | jq -r '.claims.ipaddr // ""')
    timestamp=$(echo "$latest_start" | jq -r '.eventTimestamp')
    
    # Build user identification string
    user_details="$user_info"
    if [[ -n "$user_name" && -n "$user_surname" ]]; then
        user_details="$user_name $user_surname ($user_info)"
    fi
    if [[ -n "$user_ip" ]]; then
        user_details="$user_details from IP $user_ip"
    fi
    
    # Create severity 4 issue for start operation
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` was started by $user_details" \
        --arg nextStep "Function App '$FUNCTION_APP_NAME' was started on $timestamp by $user_details. This is informational - verify if this was an expected operation." \
        --arg severity "4" \
        --arg timestamp "$timestamp" \
        --arg user "$user_details" \
        --argjson operation "$latest_start" \
        --arg portalUrl "$portal_url" \
        --arg eventLogUrl "$event_log_url" \
        '.issues += [{
            "title": $title,
            "next_step": $nextStep,
            "severity": ($severity | tonumber),
            "details": {
                "operation_type": "start",
                "timestamp": $timestamp,
                "user": $user,
                "operation_details": $operation,
                "portal_url": $portalUrl,
                "activity_log_url": $eventLogUrl
            }
        }]'
    )
    
    echo "  - Started on $timestamp by $user_details"
fi

# Process stop operations
if [[ $(echo "$stop_operations" | jq length) -gt 0 ]]; then
    echo "Found $(echo "$stop_operations" | jq length) stop operations"
    
    # Get the most recent stop operation
    latest_stop=$(echo "$stop_operations" | jq 'sort_by(.eventTimestamp) | last')
    
    # Extract user information
    user_info=$(echo "$latest_stop" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" // .caller // "Unknown User"')
    user_name=$(echo "$latest_stop" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname" // ""')
    user_surname=$(echo "$latest_stop" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname" // ""')
    user_ip=$(echo "$latest_stop" | jq -r '.claims.ipaddr // ""')
    timestamp=$(echo "$latest_stop" | jq -r '.eventTimestamp')
    
    # Build user identification string
    user_details="$user_info"
    if [[ -n "$user_name" && -n "$user_surname" ]]; then
        user_details="$user_name $user_surname ($user_info)"
    fi
    if [[ -n "$user_ip" ]]; then
        user_details="$user_details from IP $user_ip"
    fi
    
    # Determine severity based on current state
    severity="4"
    if [[ "$function_app_state" != "Running" ]]; then
        severity="2"  # Higher severity if the app is currently stopped
    fi
    
    # Create issue for stop operation
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` was stopped by $user_details" \
        --arg nextStep "Function App '$FUNCTION_APP_NAME' was stopped on $timestamp by $user_details. Current state: $function_app_state. Verify if this was intentional and if the service should be restored." \
        --arg severity "$severity" \
        --arg timestamp "$timestamp" \
        --arg user "$user_details" \
        --arg currentState "$function_app_state" \
        --argjson operation "$latest_stop" \
        --arg portalUrl "$portal_url" \
        --arg eventLogUrl "$event_log_url" \
        '.issues += [{
            "title": $title,
            "next_step": $nextStep,
            "severity": ($severity | tonumber),
            "details": {
                "operation_type": "stop",
                "timestamp": $timestamp,
                "user": $user,
                "current_state": $currentState,
                "operation_details": $operation,
                "portal_url": $portalUrl,
                "activity_log_url": $eventLogUrl
            }
        }]'
    )
    
    echo "  - Stopped on $timestamp by $user_details"
fi

# Process restart operations
if [[ $(echo "$restart_operations" | jq length) -gt 0 ]]; then
    echo "Found $(echo "$restart_operations" | jq length) restart operations"
    
    # Get the most recent restart operation
    latest_restart=$(echo "$restart_operations" | jq 'sort_by(.eventTimestamp) | last')
    
    # Extract user information
    user_info=$(echo "$latest_restart" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" // .caller // "Unknown User"')
    user_name=$(echo "$latest_restart" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname" // ""')
    user_surname=$(echo "$latest_restart" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname" // ""')
    user_ip=$(echo "$latest_restart" | jq -r '.claims.ipaddr // ""')
    timestamp=$(echo "$latest_restart" | jq -r '.eventTimestamp')
    
    # Build user identification string
    user_details="$user_info"
    if [[ -n "$user_name" && -n "$user_surname" ]]; then
        user_details="$user_name $user_surname ($user_info)"
    fi
    if [[ -n "$user_ip" ]]; then
        user_details="$user_details from IP $user_ip"
    fi
    
    # Create severity 4 issue for restart operation
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` was restarted by $user_details" \
        --arg nextStep "Function App '$FUNCTION_APP_NAME' was restarted on $timestamp by $user_details. This is informational - verify if this was an expected operation." \
        --arg severity "4" \
        --arg timestamp "$timestamp" \
        --arg user "$user_details" \
        --argjson operation "$latest_restart" \
        --arg portalUrl "$portal_url" \
        --arg eventLogUrl "$event_log_url" \
        '.issues += [{
            "title": $title,
            "next_step": $nextStep,
            "severity": ($severity | tonumber),
            "details": {
                "operation_type": "restart",
                "timestamp": $timestamp,
                "user": $user,
                "operation_details": $operation,
                "portal_url": $portalUrl,
                "activity_log_url": $eventLogUrl
            }
        }]'
    )
    
    echo "  - Restarted on $timestamp by $user_details"
fi

# Process sync operations (only report if they fail)
if [[ $(echo "$sync_operations" | jq length) -gt 0 ]]; then
    echo "Found $(echo "$sync_operations" | jq length) failed function trigger sync operations"
    
    # Get the most recent sync operation
    latest_sync=$(echo "$sync_operations" | jq 'sort_by(.eventTimestamp) | last')
    
    # Extract user information
    user_info=$(echo "$latest_sync" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" // .caller // "Unknown User"')
    user_name=$(echo "$latest_sync" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname" // ""')
    user_surname=$(echo "$latest_sync" | jq -r '.claims."http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname" // ""')
    user_ip=$(echo "$latest_sync" | jq -r '.claims.ipaddr // ""')
    timestamp=$(echo "$latest_sync" | jq -r '.eventTimestamp')
    
    # Build user identification string
    user_details="$user_info"
    if [[ -n "$user_name" && -n "$user_surname" ]]; then
        user_details="$user_name $user_surname ($user_info)"
    fi
    if [[ -n "$user_ip" ]]; then
        user_details="$user_details from IP $user_ip"
    fi
    
    # Create severity 4 issue for sync operation
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` function triggers were synced by $user_details" \
        --arg nextStep "Function App '$FUNCTION_APP_NAME' function triggers were synced on $timestamp by $user_details. This is informational - function triggers were updated." \
        --arg severity "4" \
        --arg timestamp "$timestamp" \
        --arg user "$user_details" \
        --argjson operation "$latest_sync" \
        --arg portalUrl "$portal_url" \
        --arg eventLogUrl "$event_log_url" \
        '.issues += [{
            "title": $title,
            "next_step": $nextStep,
            "severity": ($severity | tonumber),
            "details": {
                "operation_type": "function_trigger_sync",
                "timestamp": $timestamp,
                "user": $user,
                "operation_details": $operation,
                "portal_url": $portalUrl,
                "activity_log_url": $eventLogUrl
            }
        }]'
    )
    
    echo "  - Function triggers synced on $timestamp by $user_details"
fi

# If no critical operations found, create an informational issue
if [[ $(echo "$start_operations" | jq length) -eq 0 && $(echo "$stop_operations" | jq length) -eq 0 && $(echo "$restart_operations" | jq length) -eq 0 && $(echo "$sync_operations" | jq length) -eq 0 ]]; then
    echo "No critical operations found in the last $RW_LOOKBACK_WINDOW minutes"
    
    # Check if there are any recent activities at all
    if [[ $(echo "$recent_activities" | jq length) -gt 0 ]]; then
        # Get the most recent operation
        latest_operation=$(echo "$recent_activities" | jq 'sort_by(.eventTimestamp) | last')
        latest_timestamp=$(echo "$latest_operation" | jq -r '.eventTimestamp')
        latest_operation_name=$(echo "$latest_operation" | jq -r '.operationName.value')
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` - No Critical Operations" \
            --arg nextStep "No start/stop/restart/sync operations found in the last $RW_LOOKBACK_WINDOW minutes. Last operation was '$latest_operation_name' on $latest_timestamp. Current state: $function_app_state." \
            --arg severity "4" \
            --arg lastOp "$latest_operation_name" \
            --arg lastTimestamp "$latest_timestamp" \
            --arg currentState "$function_app_state" \
            --arg portalUrl "$portal_url" \
            --arg eventLogUrl "$event_log_url" \
            '.issues += [{
                "title": $title,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "details": {
                    "last_operation": $lastOp,
                    "last_operation_timestamp": $lastTimestamp,
                    "current_state": $currentState,
                    "portal_url": $portalUrl,
                    "activity_log_url": $eventLogUrl
                }
            }]'
        )
    else
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` - No Recent Activity" \
            --arg nextStep "No recent operations found for Function App '$FUNCTION_APP_NAME' in the last $RW_LOOKBACK_WINDOW minutes. Current state: $function_app_state." \
            --arg severity "4" \
            --arg currentState "$function_app_state" \
            --arg portalUrl "$portal_url" \
            --arg eventLogUrl "$event_log_url" \
            '.issues += [{
                "title": $title,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "details": {
                    "current_state": $currentState,
                    "portal_url": $portalUrl,
                    "activity_log_url": $eventLogUrl
                }
            }]'
        )
    fi
fi

# Save the results
echo "$issues_json" > "function_app_activities_issues.json"
echo "Done. Any issues found are in 'function_app_activities_issues.json'." 