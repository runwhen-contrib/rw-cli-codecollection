#!/bin/bash

# Azure Function App Recommendations and Notifications Script
# This script fetches Azure Advisor recommendations, Service Health notifications, 
# and other Azure recommendations for Function Apps
#
# ENV Variables:
# - FUNCTION_APP_NAME: Name of the Azure Function App
# - AZ_RESOURCE_GROUP: Azure Resource Group name
# - AZURE_RESOURCE_SUBSCRIPTION_ID: Azure subscription ID (optional)
# - TIME_PERIOD_DAYS: Time period to look back for notifications (default: 30)

OUTPUT_FILE="function_app_recommendations_enhanced.json"

# Set the default time period to 30 days if not provided
TIME_PERIOD_DAYS="${TIME_PERIOD_DAYS:-30}"

# Calculate the start time based on TIME_PERIOD_DAYS
start_time=$(date -u -d "$TIME_PERIOD_DAYS days ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Initialize the JSON object to store recommendations
recommendations_json=$(jq -n '{
    recommendations: [], 
    service_health: [],
    security_advisories: [],
    performance_insights: [],
    cost_optimization: [],
    summary: {}
}')

# Validate required environment variables
if [[ -z "$FUNCTION_APP_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "Error: FUNCTION_APP_NAME and AZ_RESOURCE_GROUP must be set."
    exit 1
fi

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_id=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription_id"
else
    subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription_id"
fi

echo "Switching to subscription ID: $subscription_id"
if ! az account set --subscription "$subscription_id"; then
    echo "Failed to set subscription."
    recommendations_json=$(echo "$recommendations_json" | jq \
        --arg title "Failed to Set Azure Subscription" \
        --arg details "Could not switch to subscription $subscription_id. Check subscription access" \
        --arg severity "1" \
        '.recommendations += [{"title": $title, "details": $details, "severity": ($severity | tonumber)}]')
    echo "$recommendations_json" > "$OUTPUT_FILE"
    exit 1
fi

tenant_id=$(az account show --query "tenantId" -o tsv)

# Remove previous file if it exists
[ -f "$OUTPUT_FILE" ] && rm "$OUTPUT_FILE"

echo "===== AZURE FUNCTION APP RECOMMENDATIONS & NOTIFICATIONS ====="
echo "Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Time Period: $TIME_PERIOD_DAYS days"
echo "Analysis Period: $start_time to $end_time"
echo "=============================================================="

# Get the resource ID of the Function App
if ! resource_id=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then
    echo "Error: Function App $FUNCTION_APP_NAME not found in resource group $AZ_RESOURCE_GROUP."
    recommendations_json=$(echo "$recommendations_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` Not Found" \
        --arg details "Could not find Function App $FUNCTION_APP_NAME in resource group $AZ_RESOURCE_GROUP" \
        --arg severity "1" \
        '.recommendations += [{"title": $title, "details": $details, "severity": ($severity | tonumber)}]')
    echo "$recommendations_json" > "$OUTPUT_FILE"
    exit 0
fi

# Check the current state of the Function App
function_app_state=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv 2>/dev/null)

# Generate portal URLs for easy access
portal_base_url="https://portal.azure.com/#@$tenant_id"
resource_portal_url="$portal_base_url/resource$resource_id"
advisor_url="$portal_base_url/blade/Microsoft_Azure_Expert/AdvisorMenuBlade/overview"
service_health_url="$portal_base_url/blade/Microsoft_Azure_Health/AzureHealthBrowseBlade/serviceIssues"
security_center_url="$portal_base_url/blade/Microsoft_Azure_Security/SecurityMenuBlade/0"

echo "🔗 Azure Portal Links:"
echo "   Function App: $resource_portal_url/overview"
echo "   Azure Advisor: $advisor_url"
echo "   Service Health: $service_health_url"
echo "   Security Center: $security_center_url"
echo ""

# 1. FETCH AZURE ADVISOR RECOMMENDATIONS
echo "===== FETCHING AZURE ADVISOR RECOMMENDATIONS ====="
echo "Checking for Azure Advisor recommendations..."

# Get all advisor recommendations for the subscription
advisor_recommendations=$(az advisor recommendation list --query "[?contains(resourceMetadata.resourceId, '$resource_id')]" -o json 2>/dev/null || echo "[]")

if [[ -n "$advisor_recommendations" && "$advisor_recommendations" != "[]" ]]; then
    advisor_count=$(echo "$advisor_recommendations" | jq length)
    echo "📊 Found $advisor_count Azure Advisor recommendations for this Function App"
    
    # Process advisor recommendations
    processed_advisor=$(echo "$advisor_recommendations" | jq -c '[.[] | {
        id: .id,
        category: .category,
        impact: .impact,
        title: .shortDescription.problem,
        description: .shortDescription.solution,
        resourceType: .resourceMetadata.resourceType,
        resourceName: .resourceMetadata.resourceName,
        lastUpdated: .lastUpdated,
        recommendationType: "Azure Advisor",
        portalUrl: "'$advisor_url'"
    }]')
    
    # Add to recommendations
    recommendations_json=$(echo "$recommendations_json" | jq \
        --argjson advisor "$processed_advisor" \
        '.recommendations += $advisor')
    
    # Categorize by impact
    high_impact=$(echo "$advisor_recommendations" | jq '[.[] | select(.impact == "High")] | length')
    medium_impact=$(echo "$advisor_recommendations" | jq '[.[] | select(.impact == "Medium")] | length')
    low_impact=$(echo "$advisor_recommendations" | jq '[.[] | select(.impact == "Low")] | length')
    
    echo "   📈 High Impact: $high_impact"
    echo "   📊 Medium Impact: $medium_impact"
    echo "   📉 Low Impact: $low_impact"
else
    echo "✅ No Azure Advisor recommendations found for this Function App"
fi

echo ""

# 2. FETCH SERVICE HEALTH NOTIFICATIONS
echo "===== FETCHING SERVICE HEALTH NOTIFICATIONS ====="
echo "Checking for Azure Service Health notifications..."

# Get service health events for the region and subscription
service_health_events=$(az rest --method get --url "https://management.azure.com/subscriptions/$subscription_id/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=eventType eq 'ServiceIssue' and lastUpdateTime ge '$start_time'" --query "value[?contains(affectedServices[].serviceName, 'App Service')]" -o json 2>/dev/null || echo "[]")

if [[ -n "$service_health_events" && "$service_health_events" != "[]" ]]; then
    service_health_count=$(echo "$service_health_events" | jq length)
    echo "📊 Found $service_health_count Service Health events affecting Function App"
    
    # Process service health events
    processed_service_health=$(echo "$service_health_events" | jq -c '[.[] | {
        id: .id,
        title: .title,
        description: .description,
        eventType: .eventType,
        status: .status,
        level: .level,
        lastUpdateTime: .lastUpdateTime,
        startTime: .startTime,
        endTime: .endTime,
        impactedServices: [.impactedServices[]? | select(.serviceName == "App Service")],
        recommendationType: "Service Health",
        portalUrl: "'$service_health_url'"
    }]')
    
    # Add to service health
    recommendations_json=$(echo "$recommendations_json" | jq \
        --argjson health "$processed_service_health" \
        '.service_health += $health')
    
    echo "   📋 Service Health events added to report"
else
    echo "✅ No Service Health events found affecting Function App"
fi

echo ""

# 3. FETCH SECURITY CENTER RECOMMENDATIONS
echo "===== FETCHING SECURITY CENTER RECOMMENDATIONS ====="
echo "Checking for Azure Security Center recommendations..."

# Get security assessments for the Function App
security_assessments=$(az security assessment list --query "[?resourceDetails.id == '$resource_id']" -o json 2>/dev/null || echo "[]")

if [[ -n "$security_assessments" && "$security_assessments" != "[]" ]]; then
    security_count=$(echo "$security_assessments" | jq length)
    echo "📊 Found $security_count Security Center assessments for this Function App"
    
    # Process security assessments
    processed_security=$(echo "$security_assessments" | jq -c '[.[] | {
        id: .id,
        displayName: .displayName,
        description: .metadata.description,
        severity: .metadata.severity,
        status: .status.code,
        categories: .metadata.categories,
        resourceType: .resourceDetails.resourceType,
        resourceName: .resourceDetails.resourceName,
        recommendationType: "Security Center",
        portalUrl: "'$security_center_url'"
    }]')
    
    # Add to security advisories
    recommendations_json=$(echo "$recommendations_json" | jq \
        --argjson security "$processed_security" \
        '.security_advisories += $security')
    
    echo "   🛡️ Security Center assessments added to report"
else
    echo "✅ No Security Center assessments found for this Function App"
fi

echo ""

# 4. FUNCTION APP SPECIFIC RECOMMENDATIONS
echo "===== FUNCTION APP SPECIFIC RECOMMENDATIONS ====="

# Check if Application Insights is enabled
app_insights_check=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "siteConfig.appSettings[?name=='APPINSIGHTS_INSTRUMENTATIONKEY'].value" -o tsv 2>/dev/null)

if [[ -z "$app_insights_check" ]]; then
    recommendations_json=$(echo "$recommendations_json" | jq \
        --arg title "Application Insights Not Configured for Function App \`$FUNCTION_APP_NAME\`" \
        --arg details "Function App \`$FUNCTION_APP_NAME\` does not have Application Insights configured. This limits monitoring and troubleshooting capabilities." \
        --arg severity "3" \
        '.recommendations += [{"title": $title, "details": $details, "severity": ($severity | tonumber)}]')
    echo "⚠️ Application Insights is not configured for this Function App"
fi

# Only raise cost-savings recommendation if the Function App is stopped
if [[ "$function_app_state" != "Running" ]]; then
    recommendations_json=$(echo "$recommendations_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` is Stopped - Potential Cost Savings" \
        --arg details "Stopped Function Apps may still incur costs for associated resources like storage accounts and hosting plans. | Portal URLs: Function App Portal: $resource_portal_url/overview | Advisor Dashboard: $advisor_url | Security Center: $security_center_url" \
        --arg severity "4" \
        '.recommendations += [{"title": $title, "details": $details, "severity": ($severity | tonumber)}]')
    echo "💡 Cost-savings recommendation added for stopped Function App"
fi

echo "$recommendations_json" > "$OUTPUT_FILE"
echo "===== RECOMMENDATIONS & NOTIFICATIONS ANALYSIS COMPLETE ====="
echo "Results saved to $OUTPUT_FILE" 