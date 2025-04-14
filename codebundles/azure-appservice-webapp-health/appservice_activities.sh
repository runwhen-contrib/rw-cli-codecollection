#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP
# TIME_PERIOD_MINUTES (Optional, default is 60)


# Set the default time period to 60 minutes if not provided
TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-60}"

# Calculate the start time based on TIME_PERIOD_MINUTES
start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

tenant_id=$(az account show --query "tenantId" -o tsv)
subscription_id=$(az account show --query "id" -o tsv)

# Log in to Azure CLI (uncomment if needed)
# az login --service-principal --username "$AZ_USERNAME" --password "$AZ_SECRET_VALUE" --tenant "$AZ_TENANT" > /dev/null
az account set --subscription "$subscription_id"

# Remove previous issues.json file if it exists
[ -f "issues.json" ] && rm "issues.json"

echo "Azure App Service $APP_SERVICE_NAME activity logs (recent):"

# Get the resource ID of the App Service
resource_id=$(az webapp show --name $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --query "id" -o tsv)

# Check if resource ID is found
if [[ -z "$resource_id" ]]; then
    echo "Error: App Service $APP_SERVICE_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

# List activity logs for the App Service
az monitor activity-log list --resource-id $resource_id --start-time "$start_time" --end-time "$end_time" --resource-group $AZ_RESOURCE_GROUP --output table

# Generate the event log URL
event_log_url="https://portal.azure.com/#@$tenant_id/resource/subscriptions/$subscription_id/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.Web/sites/$APP_SERVICE_NAME/eventlogs"

# Initialize the JSON object to store issues only
issues_json=$(jq -n '{issues: []}')

# Define log levels with their respective severity
declare -A log_levels=( ["Critical"]="1" ["Error"]="2" ["Warning"]="4" )

# Check for each log level in activity logs and add structured issues to issues_json
for level in "${!log_levels[@]}"; do
    # Use a refined query to gather detailed log entries within the time range
    details=$(az monitor activity-log list --resource-id $resource_id --start-time "$start_time" --end-time "$end_time" --resource-group $AZ_RESOURCE_GROUP --query "[?level=='$level']" -o json | jq -c "[.[] | {
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

    if [[ $(echo "$details" | jq length) -gt 0 ]]; then
        # Build the issue entry and add it to the issues array in issues_json
        issues_json=$(echo "$issues_json" | jq \
            --arg title "$level level issues detected for App Service \`$APP_SERVICE_NAME\` in Azure Resource Group \`$AZ_RESOURCE_GROUP\`" \
            --arg nextStep "Check the $level-level activity logs for Azure App Service \`$APP_SERVICE_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`. [Activity log URL]($event_log_url)" \
            --arg severity "${log_levels[$level]}" \
            --argjson logs "$details" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $logs}]'
        )
    fi

done

# Save the structured JSON data to issues.json
echo "$issues_json" > "app_service_activities_issues.json"