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

# Remove previous app_service_activities_issues.json file if it exists
[ -f "$OUTPUT_FILE" ] && rm "$OUTPUT_FILE"

echo "Azure App Service $APP_SERVICE_NAME activity logs (recent):"

# Get the resource ID of the App Service
if ! resource_id=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then
    echo "Error: App Service $APP_SERVICE_NAME not found in resource group $AZ_RESOURCE_GROUP."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` Not Found" \
        --arg details "Could not find App Service $APP_SERVICE_NAME in resource group $AZ_RESOURCE_GROUP. Service may not exist or access may be restricted" \
        --arg nextStep "Verify App Service name and resource group, or check access permissions for \`$APP_SERVICE_NAME\`" \
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
        --arg title "Empty Resource ID for \`$APP_SERVICE_NAME\`" \
        --arg details "App Service query returned empty resource ID. Service may not exist" \
        --arg nextStep "Verify App Service \`$APP_SERVICE_NAME\` exists in resource group \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Empty resource ID. Results saved to $OUTPUT_FILE"
    exit 0
fi

# Check the status of the App Service
app_service_state=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv 2>/dev/null)

if [[ "$app_service_state" != "Running" ]]; then
    echo "CRITICAL: App Service $APP_SERVICE_NAME is $app_service_state (not running)!"
    portal_url="https://portal.azure.com/#@/resource${resource_id}/overview"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` is $app_service_state (Not Running)" \
        --arg nextStep "Start the App Service \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` immediately to restore service availability." \
        --arg severity "1" \
        --arg details "App Service state: $app_service_state. Service is unavailable to users. Portal URL: $portal_url" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "App Service is stopped. Results saved to $OUTPUT_FILE"
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
            
            if [[ $(echo "$processed_details" | jq length) -gt 0 ]]; then
                echo "Found $level level activities"
                # Build the issue entry and add it to the issues array in issues_json
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "$level level issues detected for App Service \`$APP_SERVICE_NAME\` in Azure Resource Group \`$AZ_RESOURCE_GROUP\`" \
                    --arg nextStep "Check the $level-level activity logs for Azure App Service \`$APP_SERVICE_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`. [Activity log URL]($event_log_url)" \
                    --arg severity "${log_levels[$level]}" \
                    --argjson logs "$processed_details" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $logs}]'
                )
            else
                echo "No $level level activities found"
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