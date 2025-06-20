#!/bin/bash

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

# Input variables for subscription ID, App Service name, and resource group
issues_json='{"issues": []}'


echo "Processing app service $APP_SERVICE_NAME in resource group $AZ_RESOURCE_GROUP"

# Get App Service details
APP_SERVICE_DETAILS=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" -o json)


# Extract relevant information from JSON response
APP_SERVICE_ID=$(echo "$APP_SERVICE_DETAILS" | jq -r '.id')
LOCATION=$(echo "$APP_SERVICE_DETAILS" | jq -r '.location')
STATE=$(echo "$APP_SERVICE_DETAILS" | jq -r '.state')
KIND=$(echo "$APP_SERVICE_DETAILS" | jq -r '.kind')
APP_SERVICE_PLAN=$(echo "$APP_SERVICE_DETAILS" | jq -r '.appServicePlanId')
HTTPS_ONLY=$(echo "$APP_SERVICE_DETAILS" | jq -r '.httpsOnly')

# Share raw output
echo "-------Raw App Service Details--------"
echo "$APP_SERVICE_DETAILS" | jq .

# Checks and outputs
echo "-------Configuration Summary--------"
echo "App Service Name: $APP_SERVICE_NAME"
echo "Location: $LOCATION"
echo "State: $STATE"
echo "Kind: $KIND"
echo "App Service Plan: $APP_SERVICE_PLAN"
echo "HTTPS Only: $HTTPS_ONLY"

# Add an issue if the state is not "Running"
if [ "$STATE" != "Running" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service Not Running" \
        --arg nextStep "Check the App Service state and troubleshoot issues in the Azure Portal." \
        --arg severity "1" \
        --arg details "State: $STATE" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: App Service is not running."
fi

# Check for diagnostic settings
DIAGNOSTIC_SETTINGS=$(az monitor diagnostic-settings list --resource "$APP_SERVICE_ID" -o json | jq 'length')
if [ "$DIAGNOSTIC_SETTINGS" -gt 0 ]; then
    echo "Diagnostics settings are enabled."
else
    echo "Diagnostics settings are not enabled."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Diagnostics Settings Missing" \
        --arg nextStep "Enable diagnostics settings in the Azure Portal for \`$APP_SERVICE_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "4" \
        --arg details "Diagnostics settings are not configured for this App Service." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check HTTPS-only setting
if [ "$HTTPS_ONLY" != "true" ]; then
    echo "HTTPS is not enforced."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "HTTPS Enforcement Disabled" \
        --arg nextStep "Enable HTTPS-only setting for \`$APP_SERVICE_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "4" \
        --arg details "HTTPS is not enforced on the App Service." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    echo "HTTPS is enforced."
fi

# Check App Service Plan details
APP_SERVICE_PLAN_DETAILS=$(az appservice plan show --ids "$APP_SERVICE_PLAN" -o json)
SKUID=$(echo "$APP_SERVICE_PLAN_DETAILS" | jq -r '.sku.name')

if [ "$SKUID" == "F1" ]; then
    echo "Free App Service Plan detected."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Free App Service Plan in Use" \
        --arg nextStep "Consider upgrading to a paid App Service Plan for \`$APP_SERVICE_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "4" \
        --arg details "App Service Plan SKU: $SKUID" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    echo "App Service Plan SKU: $SKUID"
fi

# Dump the issues into a JSON list for processing
echo "$issues_json" > "az_app_service_health.json"

echo "Health check completed. Results saved to az_app_service_health.json"