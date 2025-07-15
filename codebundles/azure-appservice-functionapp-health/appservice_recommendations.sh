#!/bin/bash

# ENV:
# FUNCTION_APP_NAME - The name of the Function App
# AZ_RESOURCE_GROUP - Resource group containing the Function App
# TIME_PERIOD_DAYS - Number of days to look back for recommendations (default: 7)
# AZURE_RESOURCE_SUBSCRIPTION_ID - Azure subscription ID (optional)

# Set default values
TIME_PERIOD_DAYS="${TIME_PERIOD_DAYS:-7}"

# Calculate time range
start_time=$(date -u -d "$TIME_PERIOD_DAYS days ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Use subscription ID from environment variable
subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Using subscription ID: $subscription"

# Set the subscription
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Validate required environment variables
if [[ -z "$FUNCTION_APP_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
  echo "Error: FUNCTION_APP_NAME and AZ_RESOURCE_GROUP must be set."
  exit 1
fi

# Remove previous issues JSON file if it exists
[ -f "function_app_recommendations_issues.json" ] && rm "function_app_recommendations_issues.json"

echo "Fetching Azure Recommendations and Notifications for Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Time Range: $start_time to $end_time"

# Get Function App details
function_app_info=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "{resourceId: id, state: state, kind: kind, defaultHostName: defaultHostName}" -o json 2>/dev/null)

if [[ -z "$function_app_info" ]]; then
    echo "Error: Function App '$FUNCTION_APP_NAME' not found in resource group '$AZ_RESOURCE_GROUP'."
    exit 1
fi

resource_id=$(echo "$function_app_info" | jq -r '.resourceId')
function_app_state=$(echo "$function_app_info" | jq -r '.state')
function_app_kind=$(echo "$function_app_info" | jq -r '.kind')

echo "Function App State: $function_app_state"
echo "Function App Kind: $function_app_kind"

# Initialize the JSON object to store issues
issues_json=$(jq -n '{issues: []}')

# Function to add issue to JSON
add_issue() {
    local title="$1"
    local next_step="$2"
    local severity="$3"
    local details="$4"
    
    # Build portal URLs for easy access
    portal_url="https://portal.azure.com/#@/resource${resource_id}/overview"
    advisor_url="https://portal.azure.com/#view/Microsoft_Azure_Expert/RecommendationListBlade/source/MenuBlade/recommendationTypeId/all/subscriptionIds~/${subscription}"
    security_url="https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityMenuBlade/~/0/subscriptionIds~/${subscription}"
    
    # Add URLs to details instead of next_step
    detailed_info="$details | Portal URLs: Function App Portal: $portal_url | Advisor Dashboard: $advisor_url | Security Center: $security_url"
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg nextStep "$next_step" \
        --arg severity "$severity" \
        --arg details "$detailed_info" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
    )
}

# 1. AZURE ADVISOR RECOMMENDATIONS
echo "Fetching Azure Advisor recommendations..."

advisor_recommendations=$(az advisor recommendation list \
    --query "[?contains(resourceMetadata.resourceId, '$resource_id') || contains(resourceMetadata.resourceId, '$AZ_RESOURCE_GROUP')] | [?lastUpdated >= '$start_time']" \
    -o json 2>/dev/null | jq -c '.')

if [[ $(echo "$advisor_recommendations" | jq length) -gt 0 ]]; then
    echo "Found $(echo "$advisor_recommendations" | jq length) Azure Advisor recommendations"
    
    # Group by category
    performance_recs=$(echo "$advisor_recommendations" | jq '[.[] | select(.category == "Performance")]')
    cost_recs=$(echo "$advisor_recommendations" | jq '[.[] | select(.category == "Cost")]')
    security_recs=$(echo "$advisor_recommendations" | jq '[.[] | select(.category == "Security")]')
    reliability_recs=$(echo "$advisor_recommendations" | jq '[.[] | select(.category == "HighAvailability")]')
    
    if [[ $(echo "$performance_recs" | jq length) -gt 0 ]]; then
        perf_summary=$(echo "$performance_recs" | jq -r '.[] | "\(.shortDescription.problem) - \(.shortDescription.solution)"' | head -3)
        add_issue "Performance Recommendations for Function App \`$FUNCTION_APP_NAME\`" \
                  "Review Azure Advisor performance recommendations for Function App \`$FUNCTION_APP_NAME\`. These recommendations can help optimize application performance and user experience." \
                  "4" \
                  "$perf_summary"
    fi
    
    if [[ $(echo "$cost_recs" | jq length) -gt 0 ]]; then
        cost_summary=$(echo "$cost_recs" | jq -r '.[] | "\(.shortDescription.problem) - \(.shortDescription.solution)"' | head -3)
        add_issue "Cost Optimization Recommendations for Function App \`$FUNCTION_APP_NAME\`" \
                  "Review Azure Advisor cost recommendations for Function App \`$FUNCTION_APP_NAME\`. These recommendations can help reduce operational costs." \
                  "4" \
                  "$cost_summary"
    fi
    
    if [[ $(echo "$security_recs" | jq length) -gt 0 ]]; then
        security_summary=$(echo "$security_recs" | jq -r '.[] | "\(.shortDescription.problem) - \(.shortDescription.solution)"' | head -3)
        add_issue "Security Recommendations for Function App \`$FUNCTION_APP_NAME\`" \
                  "Review Azure Advisor security recommendations for Function App \`$FUNCTION_APP_NAME\`. These recommendations help improve security posture." \
                  "4" \
                  "$security_summary"
    fi
    
    if [[ $(echo "$reliability_recs" | jq length) -gt 0 ]]; then
        reliability_summary=$(echo "$reliability_recs" | jq -r '.[] | "\(.shortDescription.problem) - \(.shortDescription.solution)"' | head -3)
        add_issue "Reliability Recommendations for Function App \`$FUNCTION_APP_NAME\`" \
                  "Review Azure Advisor reliability recommendations for Function App \`$FUNCTION_APP_NAME\`. These recommendations help improve application reliability." \
                  "4" \
                  "$reliability_summary"
    fi
else
    echo "No Azure Advisor recommendations found"
fi

# 2. SERVICE HEALTH NOTIFICATIONS
echo "Fetching Service Health notifications..."

service_health=$(az rest \
    --method GET \
    --url "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.ResourceHealth/events?api-version=2020-05-01&\$filter=eventType eq 'ServiceIssue' and lastUpdateTime ge '$start_time'" \
    --query "value[?contains(to_string(properties.impact), 'Microsoft.Web') || contains(to_string(properties.impact), 'App Service')]" \
    -o json 2>/dev/null | jq -c '.')

if [[ $(echo "$service_health" | jq length) -gt 0 ]]; then
    echo "Found $(echo "$service_health" | jq length) Service Health notifications"
    
    # Process service health events
    while IFS= read -r event; do
        event_title=$(echo "$event" | jq -r '.properties.title')
        event_status=$(echo "$event" | jq -r '.properties.status')
        event_level=$(echo "$event" | jq -r '.properties.level')
        event_summary=$(echo "$event" | jq -r '.properties.summary')
        
        severity="4"
        if [[ "$event_level" == "Critical" ]]; then
            severity="1"
        elif [[ "$event_level" == "Warning" ]]; then
            severity="2"
        fi
        
        add_issue "Service Health Alert: $event_title" \
                  "Azure Service Health has reported an issue that may affect Function App \`$FUNCTION_APP_NAME\`. Status: $event_status. Review the service health dashboard for more details." \
                  "$severity" \
                  "$event_summary"
    done < <(echo "$service_health" | jq -c '.[]')
else
    echo "No Service Health notifications found"
fi

# 3. SECURITY CENTER ASSESSMENTS
echo "Fetching Security Center assessments..."

security_assessments=$(az rest \
    --method GET \
    --url "https://management.azure.com/subscriptions/$subscription/providers/Microsoft.Security/assessments?api-version=2020-01-01" \
    --query "value[?contains(properties.resourceDetails.id, '$resource_id') && properties.status.code != 'Healthy']" \
    -o json 2>/dev/null | jq -c '.')

if [[ $(echo "$security_assessments" | jq length) -gt 0 ]]; then
    echo "Found $(echo "$security_assessments" | jq length) Security Center assessments"
    
    security_summary=$(echo "$security_assessments" | jq -r '.[] | "\(.properties.displayName) - \(.properties.status.code)"' | head -5)
    add_issue "Security Center Assessments for Function App \`$FUNCTION_APP_NAME\`" \
              "Azure Security Center has identified security recommendations for Function App \`$FUNCTION_APP_NAME\`. Review these assessments to improve security posture." \
              "3" \
              "$security_summary"
else
    echo "No Security Center assessments found"
fi

# 4. FUNCTION APP SPECIFIC RECOMMENDATIONS
echo "Checking Function App specific recommendations..."

# Check if Application Insights is enabled
app_insights_check=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "siteConfig.appSettings[?name=='APPINSIGHTS_INSTRUMENTATIONKEY'].value" -o tsv 2>/dev/null)

if [[ -z "$app_insights_check" ]]; then
    add_issue "Application Insights Not Configured for Function App \`$FUNCTION_APP_NAME\`" \
              "Function App \`$FUNCTION_APP_NAME\` does not have Application Insights configured. This limits monitoring and troubleshooting capabilities." \
              "4" \
              "Application Insights provides performance monitoring, dependency tracking, and error analysis for Function Apps."
fi

# Check HTTPS configuration
https_only=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "httpsOnly" -o tsv 2>/dev/null)

if [[ "$https_only" != "true" ]]; then
    add_issue "HTTPS Not Enforced for Function App \`$FUNCTION_APP_NAME\`" \
              "Function App \`$FUNCTION_APP_NAME\` is not configured to enforce HTTPS only. This may expose data to security risks." \
              "4" \
              "Enable HTTPS only to ensure all traffic is encrypted in transit."
fi

# Check Managed Identity
managed_identity=$(az functionapp identity show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "type" -o tsv 2>/dev/null)

if [[ "$managed_identity" == "None" || -z "$managed_identity" ]]; then
    add_issue "Managed Identity Not Configured for Function App \`$FUNCTION_APP_NAME\`" \
              "Function App \`$FUNCTION_APP_NAME\` does not have Managed Identity enabled. This limits secure access to Azure resources without storing credentials." \
              "4" \
              "Enable Managed Identity to securely access Azure resources without managing credentials."
fi

# Check hosting plan for performance
hosting_plan=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "serverFarmId" -o tsv 2>/dev/null)

if [[ -n "$hosting_plan" ]]; then
    plan_sku=$(az appservice plan show --ids "$hosting_plan" --query "sku.name" -o tsv 2>/dev/null)
    if [[ "$plan_sku" == "Y1" || "$plan_sku" == "Dynamic" ]]; then
        add_issue "Function App \`$FUNCTION_APP_NAME\` Using Consumption Plan" \
                  "Function App \`$FUNCTION_APP_NAME\` is using a Consumption plan. Consider Premium or Dedicated plans for better performance and features if needed." \
                  "4" \
                  "Consumption plan has cold start delays and limited features compared to Premium plans."
    fi
fi

# 5. COST OPTIMIZATION CHECKS
echo "Checking cost optimization opportunities..."

# Check for unused or underutilized resources
# Only raise cost-savings recommendation if the Function App is actually stopped
if [[ "$function_app_state" != "Running" ]]; then
    add_issue "Function App \`$FUNCTION_APP_NAME\` is Stopped - Potential Cost Savings" \
              "Function App \`$FUNCTION_APP_NAME\` is currently stopped. If this is intentional and long-term, consider deleting unused resources to reduce costs." \
              "4" \
              "Stopped Function Apps may still incur costs for associated resources like storage accounts and hosting plans."
fi

# Portal URLs are now included in each issue's details via the add_issue function

# Output results
echo "$issues_json" > "function_app_recommendations_issues.json"

# Summary
total_issues=$(echo "$issues_json" | jq '.issues | length')
echo "Recommendations analysis complete. Found $total_issues recommendations/notifications."
echo "Results saved to: function_app_recommendations_issues.json"

# Create a summary
if [[ $total_issues -gt 0 ]]; then
    echo "Summary of findings:"
    echo "$issues_json" | jq -r '.issues[] | "- \(.title) (Severity \(.severity))"'
else
    echo "No recommendations or notifications found for the specified time period."
fi 