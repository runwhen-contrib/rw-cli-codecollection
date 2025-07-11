#!/bin/bash

# ENV VARS expected:
#   AZ_RESOURCE_GROUP      - name of the resource group
#   FUNCTION_APP_NAME      - name of the Azure Function App
#   AZURE_RESOURCE_SUBSCRIPTION_ID - (Optional) Subscription ID (defaults to current subscription)
#   AZ_USERNAME, AZ_SECRET_VALUE, AZ_TENANT (optional - only if you need to do an SP login)
#
# This script collects configuration information and identifies potential issues
# for an Azure Function App, including:
#  - Whether it's running
#  - Whether diagnostic settings are enabled
#  - Whether HTTPS-only is enforced
#  - Which plan SKU is being used

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

issues_json='{"issues": []}'

echo "Processing Azure Function App '$FUNCTION_APP_NAME' in resource group '$AZ_RESOURCE_GROUP'..."

# Retrieve Function App details
FUNCTION_APP_DETAILS=$(az functionapp show \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json 2>/dev/null
)

# Check if the function app was found
if [ -z "$FUNCTION_APP_DETAILS" ] || [[ "$FUNCTION_APP_DETAILS" == "null" ]]; then
  echo "Error: Function App '$FUNCTION_APP_NAME' not found in resource group '$AZ_RESOURCE_GROUP'."
  exit 1
fi

# Extract relevant information from JSON response
FUNCTION_APP_ID=$(echo "$FUNCTION_APP_DETAILS" | jq -r '.id')
LOCATION=$(echo "$FUNCTION_APP_DETAILS" | jq -r '.location')
STATE=$(echo "$FUNCTION_APP_DETAILS" | jq -r '.state')
KIND=$(echo "$FUNCTION_APP_DETAILS" | jq -r '.kind')
APP_SERVICE_PLAN=$(echo "$FUNCTION_APP_DETAILS" | jq -r '.appServicePlanId')
HTTPS_ONLY=$(echo "$FUNCTION_APP_DETAILS" | jq -r '.httpsOnly')

# Share raw output
echo "-------Raw Function App Details--------"
echo "$FUNCTION_APP_DETAILS" | jq .

# Summarize main properties
echo "-------Configuration Summary--------"
echo "Function App Name: $FUNCTION_APP_NAME"
echo "Location: $LOCATION"
echo "State: $STATE"
echo "Kind: $KIND"
echo "App Service Plan: $APP_SERVICE_PLAN"
echo "HTTPS Only: $HTTPS_ONLY"

# Issue if the Function App is not running
if [ "$STATE" != "Running" ]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App Not Running" \
        --arg nextStep "Check the Function App \`$FUNCTION_APP_NAME\` state and troubleshoot in the Azure Portal." \
        --arg severity "1" \
        --arg details "State: $STATE" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
    echo "Issue Detected: Function App is not running."
fi

# Check for diagnostic settings
DIAGNOSTIC_SETTINGS_COUNT=$(az monitor diagnostic-settings list \
  --resource "$FUNCTION_APP_ID" \
  -o json | jq 'length'
)
if [ "$DIAGNOSTIC_SETTINGS_COUNT" -gt 0 ]; then
    echo "Diagnostic settings are enabled."
else
    echo "Diagnostic settings are not enabled."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Diagnostic Settings Missing" \
        --arg nextStep "Enable diagnostic settings in the Azure Portal for \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`." \
        --arg severity "4" \
        --arg details "Diagnostic settings are not configured for this Function App." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check HTTPS-only setting
if [ "$HTTPS_ONLY" != "true" ]; then
    echo "HTTPS is not enforced."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "HTTPS Enforcement Disabled" \
        --arg nextStep "Enable the HTTPS-only setting for \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`." \
        --arg severity "4" \
        --arg details "HTTPS is not enforced on the Function App." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    echo "HTTPS is enforced."
fi

# If the Function App has an associated App Service Plan, gather more details (skips for consumption plan if empty)
if [ -n "$APP_SERVICE_PLAN" ] && [[ "$APP_SERVICE_PLAN" != "null" ]]; then
    APP_SERVICE_PLAN_DETAILS=$(az appservice plan show --ids "$APP_SERVICE_PLAN" -o json 2>/dev/null)

    if [ -n "$APP_SERVICE_PLAN_DETAILS" ] && [[ "$APP_SERVICE_PLAN_DETAILS" != "null" ]]; then
        SKUID=$(echo "$APP_SERVICE_PLAN_DETAILS" | jq -r '.sku.name')
        echo "App Service Plan SKU: $SKUID"

        # If it's a free plan, raise an informational issue
        if [ "$SKUID" == "F1" ]; then
            echo "Free App Service Plan detected."
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Free App Service Plan in Use" \
                --arg nextStep "Consider upgrading to a paid App Service Plan for \`$FUNCTION_APP_NAME\` in resource group \`$AZ_RESOURCE_GROUP\`." \
                --arg severity "4" \
                --arg details "App Service Plan SKU: $SKUID" \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
        fi
    else
        echo "Could not retrieve App Service Plan details (plan might be consumption-based or ephemeral)."
    fi
else
    echo "No explicit App Service Plan ID found (Function App may be on Consumption)."
fi

# Save the issues to a JSON file
echo "$issues_json" > "az_function_app_config_health.json"
echo "Health check completed. Results saved to az_function_app_health.json"
