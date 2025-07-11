#!/bin/bash

# ENHANCED AZURE FUNCTION APP ACTIVITY MONITORING TEMPLATE
# This script demonstrates best practices for tracking Azure activities and identifying users who made critical changes.
# 
# Key Features:
# - Proactive monitoring of critical operations (stop, start, restart, delete, configuration changes)
# - User identification with email, name, and IP address
# - Contextual issue creation with direct links to Azure portal
# - Correlation between service state and recent activities
# - Structured JSON output for integration with alerting systems
#
# ENV Variables:
# - FUNCTION_APP_NAME: Name of the Azure Function App
# - AZ_RESOURCE_GROUP: Azure Resource Group name
# - TIME_PERIOD_MINUTES: Time period to look back for activities (default: 60)
# - AZURE_RESOURCE_SUBSCRIPTION_ID: Azure subscription ID (optional)

OUTPUT_FILE="function_app_activities_enhanced.json"

# Set the default time period to 120 minutes if not provided
TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-120}"

# Calculate the start time based on TIME_PERIOD_MINUTES
start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Initialize the JSON object to store issues
issues_json=$(jq -n '{issues: [], summary: {}}')

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_id=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription_id"
else
    subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription_id"
fi

echo "Switching to subscription ID: $subscription_id"
if ! az account set --subscription "$subscription_id"; then
    echo "Failed to set subscription."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to Set Azure Subscription" \
        --arg details "Could not switch to subscription $subscription_id. Check subscription access" \
        --arg nextStep "Verify subscription access for $subscription_id and retry" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Subscription error. Results saved to $OUTPUT_FILE"
    exit 1
fi

tenant_id=$(az account show --query "tenantId" -o tsv)

# Remove previous file if it exists
[ -f "$OUTPUT_FILE" ] && rm "$OUTPUT_FILE"

echo "===== ENHANCED AZURE FUNCTION APP ACTIVITY MONITORING ====="
echo "Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Time Period: $TIME_PERIOD_MINUTES minutes"
echo "Analysis Period: $start_time to $end_time"
echo "========================================================"

# Get the resource ID of the Function App
if ! resource_id=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then
    echo "Error: Function App $FUNCTION_APP_NAME not found in resource group $AZ_RESOURCE_GROUP."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` Not Found" \
        --arg details "Could not find Function App $FUNCTION_APP_NAME in resource group $AZ_RESOURCE_GROUP. Service may not exist or access may be restricted" \
        --arg nextStep "Verify Function App name and resource group, or check access permissions for \`$FUNCTION_APP_NAME\`" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Function App not found. Results saved to $OUTPUT_FILE"
    exit 0
fi

# Check if resource ID is found
if [[ -z "$resource_id" ]]; then
    echo "Error: Empty resource ID returned for Function App $FUNCTION_APP_NAME."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Empty Resource ID for \`$FUNCTION_APP_NAME\`" \
        --arg details "Function App query returned empty resource ID. Service may not exist" \
        --arg nextStep "Verify Function App \`$FUNCTION_APP_NAME\` exists in resource group \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Empty resource ID. Results saved to $OUTPUT_FILE"
    exit 0
fi

# Generate portal URLs for easy access
portal_base_url="https://portal.azure.com/#@$tenant_id/resource"
activity_log_url="$portal_base_url$resource_id/activitylog"
overview_url="$portal_base_url$resource_id/overview"
metrics_url="$portal_base_url$resource_id/metrics"

echo "🔗 Azure Portal Links:"
echo "   Overview: $overview_url"
echo "   Activity Log: $activity_log_url"
echo "   Metrics: $metrics_url"
echo ""

# Check the current status of the Function App
echo "Checking Function App current state..."
function_app_state=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv 2>/dev/null)
function_app_health=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "availabilityState" -o tsv 2>/dev/null)

echo "Function App State: $function_app_state"
echo "Availability State: $function_app_health"

# Add current state to summary
issues_json=$(echo "$issues_json" | jq \
    --arg state "$function_app_state" \
    --arg health "$function_app_health" \
    --arg checked_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    '.summary = {
        "current_state": $state,
        "availability_state": $health,
        "checked_at": $checked_at,
        "portal_links": {
            "overview": "'$overview_url'",
            "activity_log": "'$activity_log_url'",
            "metrics": "'$metrics_url'"
        }
    }')

# If service is not running, this is critical but we still want to check activities
if [[ "$function_app_state" != "Running" ]]; then
    echo "🚨 CRITICAL: Function App $FUNCTION_APP_NAME is $function_app_state (not running)!"
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` is $function_app_state (Not Running)" \
        --arg nextStep "URGENT: Start the Function App \`$FUNCTION_APP_NAME\` in \`$AZ_RESOURCE_GROUP\` immediately to restore service availability. Check activity logs below to identify who stopped the service and when. [View Service]($overview_url)" \
        --arg severity "1" \
        --arg details "Function App state: $function_app_state. Service is unavailable to users. This may be impacting production traffic. | Activity Log: $activity_log_url" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
    
    echo "Service is stopped - analyzing recent activities to identify who made this change..."
fi

# List recent activity logs for context
echo "Fetching recent activity logs..."
az monitor activity-log list --resource-id "$resource_id" --start-time "$start_time" --end-time "$end_time" --resource-group "$AZ_RESOURCE_GROUP" --output table

echo ""
echo "===== ANALYZING CRITICAL OPERATIONS ====="

# Define critical operations that should always be flagged
critical_operations=(
    "Microsoft.Web/sites/stop/action"
    "Microsoft.Web/sites/start/action" 
    "Microsoft.Web/sites/restart/action"
    "Microsoft.Web/sites/delete/action"
    "Microsoft.Web/sites/write"
    "Microsoft.Web/sites/config/write"
    "Microsoft.Web/sites/publishxml/action"
    "Microsoft.Web/sites/slots/slotsswap/action"
    "StopWebSite"
    "StartWebSite"
    "RestartWebSite"
    "DeleteWebSite"
)

# Operation impact levels for better categorization
declare -A operation_impacts=(
    ["Microsoft.Web/sites/stop/action"]="CRITICAL - Service Outage"
    ["Microsoft.Web/sites/start/action"]="HIGH - Service Recovery"
    ["Microsoft.Web/sites/restart/action"]="MEDIUM - Service Disruption"
    ["Microsoft.Web/sites/delete/action"]="CRITICAL - Resource Destruction"
    ["Microsoft.Web/sites/write"]="MEDIUM - Configuration Change"
    ["Microsoft.Web/sites/config/write"]="MEDIUM - Configuration Change"
    ["Microsoft.Web/sites/publishxml/action"]="LOW - Deployment Access"
    ["Microsoft.Web/sites/slots/slotsswap/action"]="HIGH - Deployment Change"
    ["StopWebSite"]="CRITICAL - Service Outage"
    ["StartWebSite"]="HIGH - Service Recovery"
    ["RestartWebSite"]="MEDIUM - Service Disruption"
    ["DeleteWebSite"]="CRITICAL - Resource Destruction"
)

# Check for critical operations regardless of log level
critical_found=false
for operation in "${critical_operations[@]}"; do
    echo "Checking for operation: $operation"
    
    if critical_activities=$(az monitor activity-log list --resource-id "$resource_id" --start-time "$start_time" --end-time "$end_time" --resource-group "$AZ_RESOURCE_GROUP" --query "[?contains(operationName.value, '$operation')]" -o json 2>/dev/null); then
        if [[ -n "$critical_activities" && "$critical_activities" != "[]" ]]; then
            critical_found=true
            processed_critical=$(echo "$critical_activities" | jq -c "[.[] | {
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
            }]")
            
            if [[ $(echo "$processed_critical" | jq length) -gt 0 ]]; then
                echo "🚨 FOUND CRITICAL OPERATION: $operation"
                
                # Extract user information for the issue title
                user_email=$(echo "$processed_critical" | jq -r '.[0].claims.email // empty')
                user_name=$(echo "$processed_critical" | jq -r '.[0].claims.givenname // empty')
                user_surname=$(echo "$processed_critical" | jq -r '.[0].claims.surname // empty')
                caller=$(echo "$processed_critical" | jq -r '.[0].caller // "Unknown"')
                timestamp=$(echo "$processed_critical" | jq -r '.[0].eventTimestamp')
                status=$(echo "$processed_critical" | jq -r '.[0].status // "Unknown"')
                
                # Build user identification string
                if [[ -n "$user_email" ]]; then
                    user_info="$user_email"
                    if [[ -n "$user_name" && -n "$user_surname" ]]; then
                        user_info="$user_name $user_surname ($user_email)"
                    fi
                elif [[ -n "$user_name" && -n "$user_surname" ]]; then
                    user_info="$user_name $user_surname"
                elif [[ -n "$caller" && "$caller" != "Unknown" ]]; then
                    user_info="$caller"
                else
                    user_info="Unknown user"
                fi
                
                # Get impact level
                impact="${operation_impacts[$operation]:-UNKNOWN - Review Required}"
                
                # Determine severity based on operation and current state
                severity=1
                if [[ "$operation" == *"start"* ]] && [[ "$function_app_state" == "Running" ]]; then
                    severity=2  # Service recovery is important but less critical if already running
                elif [[ "$operation" == *"restart"* ]]; then
                    severity=2  # Restart is disruptive but not as critical as stop
                elif [[ "$operation" == *"delete"* ]]; then
                    severity=1  # Deletion is always critical
                fi
                
                echo "   👤 User: $user_info"
                echo "   📅 Time: $timestamp"
                echo "   📊 Status: $status"
                echo "   🎯 Impact: $impact"
                echo ""
                
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "⚠️ CRITICAL: '$operation' performed by $user_info on Function App \`$FUNCTION_APP_NAME\`" \
                    --arg nextStep "IMMEDIATE ACTION REQUIRED: Review the critical operation '$operation' performed at $timestamp by $user_info (Status: $status). Impact: $impact. If this was unauthorized, investigate security implications immediately and consider restoring service. [View Activity Log]($activity_log_url) | [View Service]($overview_url)" \
                    --arg severity "$severity" \
                    --arg user "$user_info" \
                    --arg operation "$operation" \
                    --arg impact "$impact" \
                    --arg timestamp "$timestamp" \
                    --argjson logs "$processed_critical" \
                    '.issues += [{
                        "title": $title, 
                        "next_step": $nextStep, 
                        "severity": ($severity | tonumber), 
                        "user": $user,
                        "operation": $operation,
                        "impact": $impact,
                        "timestamp": $timestamp,
                        "details": $logs
                    }]'
                )
            fi
        fi
    fi
done

if [[ "$critical_found" == false ]]; then
    echo "✅ No critical operations found in the specified time period."
fi

echo ""
echo "===== ANALYZING GENERAL ACTIVITY LEVELS ====="

# Define log levels with their respective severity
declare -A log_levels=( ["Critical"]="1" ["Error"]="2" ["Warning"]="4" )

# Check for each log level in activity logs
for level in "${!log_levels[@]}"; do
    echo "Checking for $level level activities..."
    
    if details=$(az monitor activity-log list --resource-id "$resource_id" --start-time "$start_time" --end-time "$end_time" --resource-group "$AZ_RESOURCE_GROUP" --query "[?level=='$level']" -o json 2>/dev/null); then
        if [[ -n "$details" && "$details" != "[]" ]]; then
            # Process the details with jq
            processed_details=$(echo "$details" | jq -c "[.[] | {
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
            }]")
            
            activity_count=$(echo "$processed_details" | jq length)
            if [[ "$activity_count" -gt 0 ]]; then
                echo "📊 Found $activity_count $level level activities"
                
                # Build the issue entry and add it to the issues array
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "$level level activities detected for Function App \`$FUNCTION_APP_NAME\` ($activity_count events)" \
                    --arg nextStep "Review the $activity_count $level-level activity events for Azure Function App \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`. These may indicate system issues or configuration problems. [View Activity Log]($activity_log_url)" \
                    --arg severity "${log_levels[$level]}" \
                    --arg count "$activity_count" \
                    --argjson logs "$processed_details" \
                    '.issues += [{
                        "title": $title, 
                        "next_step": $nextStep, 
                        "severity": ($severity | tonumber), 
                        "activity_count": ($count | tonumber),
                        "details": $logs
                    }]'
                )
            else
                echo "✅ No $level level activities found"
            fi
        else
            echo "✅ No $level level activities found"
        fi
    else
        echo "⚠️ Warning: Could not query $level level activities"
    fi
done

# Add final summary information
total_issues=$(echo "$issues_json" | jq '.issues | length')
echo ""
echo "===== SUMMARY ====="
echo "Total issues found: $total_issues"
echo "Function App state: $function_app_state"
echo "Analysis period: $TIME_PERIOD_MINUTES minutes"
echo "Output file: $OUTPUT_FILE"
echo ""

# Update summary with final counts
issues_json=$(echo "$issues_json" | jq \
    --arg total_issues "$total_issues" \
    --arg analysis_period "$TIME_PERIOD_MINUTES" \
    '.summary.total_issues = ($total_issues | tonumber) |
     .summary.analysis_period_minutes = ($analysis_period | tonumber) |
     .summary.report_generated_at = "'"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"'"')

# Always save the structured JSON data
echo "$issues_json" > "$OUTPUT_FILE"

if [[ "$total_issues" -gt 0 ]]; then
    echo "🚨 Issues detected! Check the detailed report in $OUTPUT_FILE"
    echo "Key portal links:"
    echo "  - Service Overview: $overview_url"
    echo "  - Activity Log: $activity_log_url"
    echo "  - Metrics: $metrics_url"
else
    echo "✅ No issues detected during the analysis period."
fi

echo ""
echo "Activity log analysis completed successfully."
echo "Results saved to $OUTPUT_FILE" 