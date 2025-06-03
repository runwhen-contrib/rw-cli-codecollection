#!/bin/bash

# ENV:
# FUNCTION_APP_NAME
# AZ_RESOURCE_GROUP
# TIME_PERIOD_MINUTES (Optional, default is 60)
# AZURE_RESOURCE_SUBSCRIPTION_ID (Optional, defaults to current subscription)

# Set the default time period to 60 minutes if not provided
TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-60}"

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

# List activity logs for the Function App
az monitor activity-log list \
  --resource-id "$resource_id" \
  --start-time "$start_time" \
  --end-time "$end_time" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --output table

# Build a link for the Azure Portal event logs (optional convenience)
tenant_id=$(az account show --query "tenantId" -o tsv)
subscription_id=$(az account show --query "id" -o tsv)
event_log_url="https://portal.azure.com/#@$tenant_id/resource/subscriptions/$subscription_id/resourceGroups/$AZ_RESOURCE_GROUP/providers/Microsoft.Web/sites/$FUNCTION_APP_NAME/eventlogs"

# Initialize an empty JSON object to store issues
issues_json=$(jq -n '{issues: []}')

# Define log levels with a severity mapping for your tasks
declare -A log_levels=( ["Critical"]="1" ["Error"]="2" ["Warning"]="4" )

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
            --arg title "$level level issues detected for Azure Function App \`$FUNCTION_APP_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`" \
            --arg nextStep "Review the $level-level activity logs for Azure Function App \`$FUNCTION_APP_NAME\`. [Activity log URL]($event_log_url)" \
            --arg severity "${log_levels[$level]}" \
            --argjson logs "$details" \
            '.issues += [{
                "title": $title,
                "next_step": $nextStep,
                "severity": ($severity | tonumber),
                "details": $logs
            }]'
        )
    fi
done

# Save the results
echo "$issues_json" > "function_app_activities_issues.json"
echo "Done. Any issues found are in 'function_app_activities_issues.json'."
