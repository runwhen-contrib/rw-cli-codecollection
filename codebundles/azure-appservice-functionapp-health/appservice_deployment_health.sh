#!/bin/bash

# ENVIRONMENT VARIABLES:
#   FUNCTION_APP_NAME  - The name of the Azure Function App
#   AZ_RESOURCE_GROUP  - The name of the resource group containing the Function App
#   CHECK_PERIOD       - (Optional) Period in hours to consider “recent.” Default: 24
#   AZ_SUBSCRIPTION    - (Optional) If you want to set a specific subscription
#   (Optional) AZ_USERNAME, AZ_SECRET_VALUE, AZ_TENANT (for service principal login, if needed)

# PERIOD in hours to check for recent deployments (if you track them)
CHECK_PERIOD="${CHECK_PERIOD:-24}"

# If needed, log in as an SP or switch subscriptions:
# az login --service-principal --username "$AZ_USERNAME" --password "$AZ_SECRET_VALUE" --tenant "$AZ_TENANT" > /dev/null
[ -n "$AZ_SUBSCRIPTION" ] && az account set --subscription "$AZ_SUBSCRIPTION"

# Ensure required variables
if [[ -z "$FUNCTION_APP_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "Error: FUNCTION_APP_NAME and AZ_RESOURCE_GROUP must be set."
    exit 1
fi

echo "Checking deployment health for Function App '$FUNCTION_APP_NAME' in resource group '$AZ_RESOURCE_GROUP'"

issues_json='{"issues": []}'

#-----------------------------------------------------------------------------
# 1. Check for Deployment Slots
#-----------------------------------------------------------------------------
echo "Checking function app deployment slots..."
DEPLOYMENTS=$(az functionapp deployment slot list \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json 2>/dev/null)

if [[ -z "$DEPLOYMENTS" || "$DEPLOYMENTS" == "[]" ]]; then
    echo "No deployment slots found. Checking production configuration..."

    # Retrieve the production function’s info
    DEPLOYMENT_CONFIG=$(az functionapp show \
      --name "$FUNCTION_APP_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      -o json 2>/dev/null)

    if [[ -z "$DEPLOYMENT_CONFIG" || "$DEPLOYMENT_CONFIG" == "null" ]]; then
        echo "Error: Failed to fetch production deployment configuration. Verify the Function App and resource group."
        exit 1
    fi

    PROD_STATE=$(echo "$DEPLOYMENT_CONFIG" | jq -r '.state // empty')

    if [[ -z "$PROD_STATE" ]]; then
        echo "Warning: Production state could not be determined."
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Production State Missing" \
            --arg nextStep "Check the Function App state in the Azure Portal." \
            --arg severity "3" \
            --arg details "Unable to fetch the state for the production deployment." \
            '.issues += [{
                "title": $title, 
                "details": $details, 
                "next_step": $nextStep, 
                "severity": ($severity | tonumber)
            }]'
        )
    elif [[ "$PROD_STATE" != "Running" ]]; then
        echo "Production is in state: $PROD_STATE"
        issues_json=$(echo "$issues_json" | jq \
            --arg state "$PROD_STATE" \
            --arg title "Production Deployment Issue with Function App \`$FUNCTION_APP_NAME\` " \
            --arg nextStep "Investigate the production Function App \`$FUNCTION_APP_NAME\` in the Azure Portal." \
            --arg severity "1" \
            --arg config "$DEPLOYMENT_CONFIG" \
            '.issues += [{
                "title": $title, 
                "details": ("Slot state: \($state)"),
                "deployment_configuration": $config, 
                "next_step": $nextStep, 
                "severity": ($severity | tonumber)
            }]'
        )
    else
        echo "Production deployment is running."
    fi
else
    # If slots exist, iterate through them
    for slot in $(echo "$DEPLOYMENTS" | jq -r '.[].name'); do
        echo "Checking slot: $slot"

        SLOT_DETAILS=$(az functionapp deployment slot show \
          --name "$FUNCTION_APP_NAME" \
          --slot "$slot" \
          --resource-group "$AZ_RESOURCE_GROUP" \
          -o json 2>/dev/null)

        SLOT_STATE=$(echo "$SLOT_DETAILS" | jq -r '.state // empty')

        # Debug slot state
        echo "Slot '$slot' state: $SLOT_STATE"

        if [[ -z "$SLOT_STATE" ]]; then
            # Possibly the CLI didn't return "state" for function slots
            echo "Warning: State missing for slot '$slot'."
            issues_json=$(echo "$issues_json" | jq \
                --arg slot "$slot" \
                --arg title "Slot State Missing for Function App \`$FUNCTION_APP_NAME\`" \
                --arg nextStep "Check the slot \`$slot\` in the Azure Portal." \
                --arg severity "3" \
                --arg config "$SLOT_DETAILS" \
                '.issues += [{
                    "title": $title, 
                    "details": "Slot state not returned by CLI", 
                    "slot": $slot, 
                    "deployment_configuration": $config, 
                    "next_step": $nextStep, 
                    "severity": ($severity | tonumber)
                }]'
            )
        elif [[ "$SLOT_STATE" != "Running" ]]; then
            echo "Slot '$slot' is in state: $SLOT_STATE"
            issues_json=$(echo "$issues_json" | jq \
                --arg slot "$slot" \
                --arg state "$SLOT_STATE" \
                --arg title "Deployment Slot Issue with Function App \`$FUNCTION_APP_NAME\`" \
                --arg nextStep "Investigate the issue with slot \`$slot\` in the Azure Portal." \
                --arg severity "2" \
                --arg config "$SLOT_DETAILS" \
                '.issues += [{
                    "title": $title, 
                    "details": ("Production state: \($state)"), 
                    "slot": $slot, 
                    "deployment_configuration": $config, 
                    "next_step": $nextStep, 
                    "severity": ($severity | tonumber)
                }]'
            )
        fi
    done
fi

#-----------------------------------------------------------------------------
# 2. Check for “recent failed or stuck deployments”
#    NOTE: Unlike Web Apps, there's no `az functionapp log deployment show`.
#    If you rely on Kudu or other logs, integrate them below.
#-----------------------------------------------------------------------------

echo "NOTE: 'az functionapp log deployment show' is not available. Function Apps do not expose deployment logs the same way as Web Apps."
echo "If using Kudu for deployment, you can query Kudu's API directly or rely on your CI/CD logs."

# Placeholder to highlight the user must rely on alternative logs
echo "No deployment logs to analyze. Skipping deployment log checks..."

#-----------------------------------------------------------------------------
# 3. Output results
#-----------------------------------------------------------------------------
echo "$issues_json" | jq '.' > "deployment_health.json"
echo "Deployment health check completed. Results saved to deployment_health.json"
