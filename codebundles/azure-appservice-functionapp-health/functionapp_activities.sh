#!/bin/bash

# ENV:
# FUNCTION_APP_NAME
# AZ_RESOURCE_GROUP
# TIME_PERIOD_MINUTES (Optional, default is 120)
# AZURE_RESOURCE_SUBSCRIPTION_ID (Optional, defaults to current subscription)

# Set the default time period to 120 minutes if not provided
TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-120}"

# Calculate the start and end times
start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

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

# Get all activities for the function app, filtering out noise
all_activities_main=$(az monitor activity-log list \
    --resource-id "$resource_id" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    --query "[?operationName.value != 'Microsoft.Web/sites/publishxml/action' && operationName.value != 'Microsoft.Web/sites/backup/action' && operationName.value != 'Microsoft.Web/sites/backup/read']" \
    -o json 2>/dev/null)

# Get host activities
host_resource_id="$resource_id/host/default"
all_activities_host=$(az monitor activity-log list \
    --resource-id "$host_resource_id" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

# Combine both sets of activities
all_activities=$(echo "$all_activities_main" | jq -s '.[0] + .[1]' <(echo "$all_activities_host"))

echo "Function App specific activities (filtered):"
echo "$all_activities" | jq -r '.[] | "\(.caller)\t\(.correlationId)\t\(.description)\t\(.eventDataId)\t\(.eventTimestamp)\t\(.level)\t\(.operationId)\t\(.resourceGroupName)\t\(.resourceGroupName)\t\(.resourceId)\t\(.submissionTimestamp)\t\(.subscriptionId)\t\(.tenantId)"' | column -t -s $'\t'

# Search for start/stop operations specifically
echo ""
echo "Searching for start/stop operations on Function App '$FUNCTION_APP_NAME'..."

# Use a 7-day window for start/stop operations to capture important operational events
extended_start_time=$(date -u -d "7 days ago" '+%Y-%m-%dT%H:%M:%SZ')

# Search for start operations (using correct Azure operation names)
# Also check host resource for start operations
start_operations_main=$(az monitor activity-log list \
    --resource-id "$resource_id" \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

start_operations_host=$(az monitor activity-log list \
    --resource-id "$host_resource_id" \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

# Also try searching at the subscription level for start operations
start_operations_subscription=$(az monitor activity-log list \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    --query "[?resourceId == '$resource_id' && operationName.value != null && (contains(operationName.value, 'start') || contains(operationName.value, 'Start') || contains(operationName.value, 'Microsoft.Web/sites/start') || contains(operationName.value, 'Microsoft.Web/sites/start/action'))]" \
    -o json 2>/dev/null)

# Combine all sets and filter for start operations using jq
start_operations=$(echo "$start_operations_main" | jq -s '.[0] + .[1] + .[2]' <(echo "$start_operations_host") <(echo "$start_operations_subscription") | jq '[.[] | select(.operationName.value != null and (.operationName.value | contains("start") or contains("Start") or contains("Microsoft.Web/sites/start") or contains("Microsoft.Web/sites/start/action")))]')

# Note: Azure Activity Log API may not return all start/stop events due to indexing delays or filtering

# Search for stop operations (using correct Azure operation names)
# Also check host resource for stop operations
stop_operations_main=$(az monitor activity-log list \
    --resource-id "$resource_id" \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

stop_operations_host=$(az monitor activity-log list \
    --resource-id "$host_resource_id" \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

# Also try searching at the subscription level for stop operations
stop_operations_subscription=$(az monitor activity-log list \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    --query "[?resourceId == '$resource_id' && operationName.value != null && (contains(operationName.value, 'stop') || contains(operationName.value, 'Stop') || contains(operationName.value, 'Microsoft.Web/sites/stop') || contains(operationName.value, 'Microsoft.Web/sites/stop/action'))]" \
    -o json 2>/dev/null)

# Combine all sets and filter for stop operations using jq
stop_operations=$(echo "$stop_operations_main" | jq -s '.[0] + .[1] + .[2]' <(echo "$stop_operations_host") <(echo "$stop_operations_subscription") | jq '[.[] | select(.operationName.value != null and (.operationName.value | contains("stop") or contains("Stop") or contains("Microsoft.Web/sites/stop") or contains("Microsoft.Web/sites/stop/action")))]')

# Search for restart operations (using correct Azure operation names)
# Also check host resource for restart operations
restart_operations_main=$(az monitor activity-log list \
    --resource-id "$resource_id" \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

restart_operations_host=$(az monitor activity-log list \
    --resource-id "$host_resource_id" \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

# Also try searching at the subscription level for restart operations
restart_operations_subscription=$(az monitor activity-log list \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    --query "[?resourceId == '$resource_id' && operationName.value != null && (contains(operationName.value, 'restart') || contains(operationName.value, 'Restart') || contains(operationName.value, 'Microsoft.Web/sites/restart') || contains(operationName.value, 'Microsoft.Web/sites/restart/action'))]" \
    -o json 2>/dev/null)

# Combine all sets and filter for restart operations using jq
restart_operations=$(echo "$restart_operations_main" | jq -s '.[0] + .[1] + .[2]' <(echo "$restart_operations_host") <(echo "$restart_operations_subscription") | jq '[.[] | select(.operationName.value != null and (.operationName.value | contains("restart") or contains("Restart") or contains("Microsoft.Web/sites/restart") or contains("Microsoft.Web/sites/restart/action")))]')

# Search for function trigger sync operations (only report if they fail)
# Check both the main resource and the host resource
sync_operations_main=$(az monitor activity-log list \
    --resource-id "$resource_id" \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

# Check host resource for sync operations
host_resource_id="$resource_id/host/default"
sync_operations_host=$(az monitor activity-log list \
    --resource-id "$host_resource_id" \
    --start-time "$extended_start_time" \
    --end-time "$end_time" \
    -o json 2>/dev/null)

# Combine both sets and filter for failed sync operations using jq
sync_operations=$(echo "$sync_operations_main" | jq -s '.[0] + .[1]' <(echo "$sync_operations_host") | jq '[.[] | select(.operationName.value != null and (.operationName.value | contains("host/sync") or contains("host/sync/action")) and .status.value == "Failed")]')

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
    
    # Create severity 4 issue for start operation with all events
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App '$FUNCTION_APP_NAME' was started by $user_details" \
        --arg nextStep "Function App '$FUNCTION_APP_NAME' was started on $timestamp by $user_details. This is informational - verify if this was an expected operation." \
        --arg severity "4" \
        --arg timestamp "$timestamp" \
        --arg user "$user_details" \
        --argjson operation "$latest_start" \
        --argjson allEvents "$start_operations" \
        --arg portalUrl "$portal_url" \
        --arg eventLogUrl "$event_log_url" \
        '.issues += [{
            "title": $title,
            "next_step": $nextStep,
            "severity": ($severity | tonumber),
            "details": {
                "operation_type": "start",
                "latest_timestamp": $timestamp,
                "user": $user,
                "latest_operation_details": $operation,
                "all_start_events": $allEvents,
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
    
    # Create issue for stop operation with all events
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App '$FUNCTION_APP_NAME' was stopped by $user_details" \
        --arg nextStep "Function App '$FUNCTION_APP_NAME' was stopped on $timestamp by $user_details. Current state: $function_app_state. Verify if this was intentional and if the service should be restored." \
        --arg severity "$severity" \
        --arg timestamp "$timestamp" \
        --arg user "$user_details" \
        --arg currentState "$function_app_state" \
        --argjson operation "$latest_stop" \
        --argjson allEvents "$stop_operations" \
        --arg portalUrl "$portal_url" \
        --arg eventLogUrl "$event_log_url" \
        '.issues += [{
            "title": $title,
            "next_step": $nextStep,
            "severity": ($severity | tonumber),
            "details": {
                "operation_type": "stop",
                "latest_timestamp": $timestamp,
                "user": $user,
                "current_state": $currentState,
                "latest_operation_details": $operation,
                "all_stop_events": $allEvents,
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
    
    # Create severity 4 issue for restart operation with all events
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App '$FUNCTION_APP_NAME' was restarted by $user_details" \
        --arg nextStep "Function App '$FUNCTION_APP_NAME' was restarted on $timestamp by $user_details. This is informational - verify if this was an expected operation." \
        --arg severity "4" \
        --arg timestamp "$timestamp" \
        --arg user "$user_details" \
        --argjson operation "$latest_restart" \
        --argjson allEvents "$restart_operations" \
        --arg portalUrl "$portal_url" \
        --arg eventLogUrl "$event_log_url" \
        '.issues += [{
            "title": $title,
            "next_step": $nextStep,
            "severity": ($severity | tonumber),
            "details": {
                "operation_type": "restart",
                "latest_timestamp": $timestamp,
                "user": $user,
                "latest_operation_details": $operation,
                "all_restart_events": $allEvents,
                "portal_url": $portalUrl,
                "activity_log_url": $eventLogUrl
            }
        }]'
    )
    
    echo "  - Restarted on $timestamp by $user_details"
fi

# Process sync operations (function trigger sync)
if [[ $(echo "$sync_operations" | jq length) -gt 0 ]]; then
    echo "Found $(echo "$sync_operations" | jq length) function trigger sync operations"
    
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
        --arg title "Function App '$FUNCTION_APP_NAME' function triggers were synced by $user_details" \
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

# If no start/stop/sync operations found, create an informational issue
if [[ $(echo "$start_operations" | jq length) -eq 0 && $(echo "$stop_operations" | jq length) -eq 0 && $(echo "$restart_operations" | jq length) -eq 0 && $(echo "$sync_operations" | jq length) -eq 0 ]]; then
    echo "No start/stop/restart operations found in the last 7 days (Note: Azure Activity Log API may not return all events due to indexing delays)"
    
    # Search for any operations in the last 7 days to see when it was last modified
    week_start_time=$(date -u -d "7 days ago" '+%Y-%m-%dT%H:%M:%SZ')
    
    recent_operations=$(az monitor activity-log list \
        --resource-id "$resource_id" \
        --start-time "$week_start_time" \
        --end-time "$end_time" \
        --query "[?operationName.value != 'Microsoft.Web/sites/publishxml/action']" \
        -o json 2>/dev/null)
    
    if [[ $(echo "$recent_operations" | jq length) -gt 0 ]]; then
        # Get the most recent operation
        latest_operation=$(echo "$recent_operations" | jq 'sort_by(.eventTimestamp) | last')
        latest_timestamp=$(echo "$latest_operation" | jq -r '.eventTimestamp')
        latest_operation_name=$(echo "$latest_operation" | jq -r '.operationName.value')
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Function App '$FUNCTION_APP_NAME' - No Recent Activity" \
            --arg nextStep "No start/stop/restart/sync operations found in the last 7 days. Last operation was '$latest_operation_name' on $latest_timestamp. Current state: $function_app_state." \
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
            --arg title "Function App '$FUNCTION_APP_NAME' - No Recent Activity" \
            --arg nextStep "No recent operations found for Function App '$FUNCTION_APP_NAME' in the last 7 days. Current state: $function_app_state. This may indicate the Function App has been inactive or was created in its current state." \
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

# Fallback: Always check for state changes in resource properties (regardless of whether other operations were found)
echo "Checking for state changes in resource properties as fallback..."

# Get current resource state and last modified time
current_resource_info=$(az functionapp show \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --query "{state: state, lastModifiedTimeUtc: lastModifiedTimeUtc}" \
    -o json 2>/dev/null)

if [[ -n "$current_resource_info" && "$current_resource_info" != "{}" ]]; then
    current_state=$(echo "$current_resource_info" | jq -r '.state // "unknown"')
    last_modified=$(echo "$current_resource_info" | jq -r '.lastModifiedTimeUtc // "unknown"')
    
    # Check if last modified is within 1 day
    if [[ "$last_modified" != "unknown" ]]; then
        # Convert to timestamp for comparison
        last_modified_timestamp=$(date -d "$last_modified" +%s 2>/dev/null || echo "0")
        one_day_ago_timestamp=$(date -d "1 day ago" +%s 2>/dev/null || echo "0")
        
        if [[ $last_modified_timestamp -gt $one_day_ago_timestamp ]]; then
            echo "Detected recent state change: Last modified on $last_modified, current state: $current_state"
            
            # Create informational issue about state change
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Function App '$FUNCTION_APP_NAME' state change detected via resource properties" \
                --arg nextStep "Function App '$FUNCTION_APP_NAME' was last modified on $last_modified and is currently in state '$current_state'. No corresponding Activity Log event was found. Please check the Azure Portal Event Logs for more details." \
                --arg severity "4" \
                --arg lastModified "$last_modified" \
                --arg currentState "$current_state" \
                --arg portalUrl "$portal_url" \
                --arg eventLogUrl "$event_log_url" \
                '.issues += [{
                    "title": $title,
                    "next_step": $nextStep,
                    "severity": ($severity | tonumber),
                    "details": {
                        "operation_type": "state_change_detected",
                        "last_modified": $lastModified,
                        "current_state": $currentState,
                        "note": "State change detected via resource properties. Activity Log API may not have returned the corresponding event.",
                        "portal_url": $portalUrl,
                        "activity_log_url": $eventLogUrl
                    }
                }]'
            )
        else
            echo "No recent state changes detected (last modified: $last_modified)"
        fi
    fi
fi

# Save the results
echo "$issues_json" > "function_app_activities_issues.json"
echo "Done. Any issues found are in 'function_app_activities_issues.json'." 