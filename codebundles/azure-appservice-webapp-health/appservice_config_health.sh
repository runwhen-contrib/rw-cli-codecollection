#!/bin/bash

# Use existing subscription name variable
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

SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

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
        --arg title "App Service \`$APP_SERVICE_NAME\` Not Running in subscription \`$SUBSCRIPTION_NAME\`" \
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
        --arg title "Diagnostics Settings Missing for \`$APP_SERVICE_NAME\` in subscription \`$SUBSCRIPTION_NAME\`" \
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
        --arg title "HTTPS Enforcement Disabled for \`$APP_SERVICE_NAME\` in subscription \`$SUBSCRIPTION_NAME\`" \
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
        --arg title "Free App Service Plan in Use for \`$APP_SERVICE_NAME\` in subscription \`$SUBSCRIPTION_NAME\`" \
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