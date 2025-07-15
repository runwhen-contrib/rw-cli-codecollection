#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP
# AZURE_RESOURCE_SUBSCRIPTION_ID (Optional, defaults to current subscription)
# TIME_PERIOD_MINUTES (Optional, default is 60)

OUTPUT_FILE="app_service_activities_issues.json"

# Set the default time period to 60 minutes if not provided
TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-60}"

# Calculate the start time based on TIME_PERIOD_MINUTES
start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Initialize the JSON object to store issues only - this ensures we always have valid output
issues_json=$(jq -n '{issues: []}')

# Get subscription name from environment variable
SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_id=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription_id"
else
    subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription_id"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription_id"
if ! az account set --subscription "$subscription_id"; then
    echo "Failed to set subscription."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Azure subscription access failed for \`$SUBSCRIPTION_NAME\`" \
        --arg details "Could not switch to subscription $subscription_id. Check subscription access" \
        --arg nextStep "Verify subscription access and authentication for \`$SUBSCRIPTION_NAME\`" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Subscription error. Results saved to $OUTPUT_FILE"
    exit 1
fi

tenant_id=$(az account show --query "tenantId" -o tsv)

# Remove previous file if it exists
[ -f "$OUTPUT_FILE" ] && rm "$OUTPUT_FILE"

echo "===== AZURE APP SERVICE ACTIVITY MONITORING ====="
echo "App Service: $APP_SERVICE_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Subscription: $SUBSCRIPTION_NAME"
echo "Time Period: $TIME_PERIOD_MINUTES minutes"
echo "Analysis Period: $start_time to $end_time"
echo "===================================================="

# Get the resource ID of the App Service
if ! resource_id=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then
    echo "Error: App Service $APP_SERVICE_NAME not found in resource group $AZ_RESOURCE_GROUP."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` in subscription \`$SUBSCRIPTION_NAME\` not found" \
        --arg details "Could not find App Service $APP_SERVICE_NAME in resource group $AZ_RESOURCE_GROUP. Service may not exist or access may be restricted" \
        --arg nextStep "Verify App Service name and resource group exist, then check access permissions" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "App Service not found. Results saved to $OUTPUT_FILE"
    exit 0
fi

# Check if resource ID is found
if [[ -z "$resource_id" ]]; then
    echo "Error: Empty resource ID returned for App Service $APP_SERVICE_NAME."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` in subscription \`$SUBSCRIPTION_NAME\` returned empty resource ID" \
        --arg details "App Service query returned empty resource ID. Service may not exist" \
        --arg nextStep "Verify App Service exists and is properly configured in the resource group" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Empty resource ID. Results saved to $OUTPUT_FILE"
    exit 0
fi

# List activity logs for the App Service
echo "Fetching activity logs for resource ID: $resource_id"
az monitor activity-log list --resource-id "$resource_id" --start-time "$start_time" --end-time "$end_time" --resource-group "$AZ_RESOURCE_GROUP" --output table

# Generate the event log URL
event_log_url="https://portal.azure.com/#@$tenant_id/resource/subscriptions/$subscription_id/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.Web/sites/$APP_SERVICE_NAME/eventlogs"

# Define log levels with their respective severity
declare -A log_levels=( ["Critical"]="1" ["Error"]="2" ["Warning"]="4" )

# Check for each log level in activity logs and add structured issues to issues_json
for level in "${!log_levels[@]}"; do
    echo "Checking for $level level activities..."
    
    # Use a refined query to gather detailed log entries within the time range
    if details=$(az monitor activity-log list --resource-id "$resource_id" --start-time "$start_time" --end-time "$end_time" --resource-group "$AZ_RESOURCE_GROUP" --query "[?level=='$level']" -o json 2>/dev/null); then
        if [[ -n "$details" && "$details" != "[]" ]]; then
            # Filter out ignored operations from the details
            filtered_details=$(echo "$details" | jq -c "[.[] | select(.authorization.action as \$action | [\"Microsoft.Web/sites/publishxml/action\", \"Microsoft.Web/sites/listsyncfunctiontriggerstatus/action\", \"Microsoft.Web/sites/read\", \"Microsoft.Web/sites/config/read\", \"Microsoft.Web/sites/slots/read\"] | contains([\$action]) | not)]")
            
            # Process the filtered details with jq
            processed_details=$(echo "$filtered_details" | jq -c "[.[] | {
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
                echo "Found $activity_count $level level activities"
                # Build the issue entry and add it to the issues array in issues_json
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "App Service \`$APP_SERVICE_NAME\` in subscription \`$SUBSCRIPTION_NAME\` has $activity_count $level level activities" \
                    --arg nextStep "Review the $level-level activity events to identify potential system issues or configuration problems" \
                    --arg severity "${log_levels[$level]}" \
                    --argjson logs "$processed_details" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $logs}]'
                )
            else
                echo "No significant $level level activities found (filtered out routine operations)"
            fi
        else
            echo "No $level level activities found"
        fi
    else
        echo "Warning: Could not query $level level activities"
    fi
done

# Always save the structured JSON data
echo "$issues_json" > "$OUTPUT_FILE"
echo "Activity log analysis completed. Results saved to $OUTPUT_FILE"