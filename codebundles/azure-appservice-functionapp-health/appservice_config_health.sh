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

# Use subscription ID from environment variable
# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Using subscription ID: $subscription"

# Get subscription name from environment variable
subscription_name="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

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
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

  # Extract timestamp from log context


  log_timestamp=$(extract_log_timestamp "$0")


  echo "Error: Function App '$FUNCTION_APP_NAME' not found in resource group '$AZ_RESOURCE_GROUP'. (detected at $log_timestamp)"
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
        --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` Not Running" \
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
        --arg title "Diagnostic Settings Missing for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
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
        --arg title "HTTPS Enforcement Disabled for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
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
                --arg title "Free App Service Plan in Use for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
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
