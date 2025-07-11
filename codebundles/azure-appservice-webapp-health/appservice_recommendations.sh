#!/bin/bash

# Azure App Service Recommendations and Notifications Script
# This script fetches Azure Advisor recommendations, Service Health notifications, 
# and other Azure recommendations for Web Apps
#
# ENV Variables:
# - APP_SERVICE_NAME: Name of the Azure App Service
# - AZ_RESOURCE_GROUP: Azure Resource Group name
# - AZURE_RESOURCE_SUBSCRIPTION_ID: Azure subscription ID (optional)
# - TIME_PERIOD_DAYS: Time period to look back for notifications (default: 30)

OUTPUT_FILE="app_service_recommendations.json"

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
if [[ -z "$APP_SERVICE_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "Error: APP_SERVICE_NAME and AZ_RESOURCE_GROUP must be set."
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

# Set the subscription to the determined ID
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

echo "===== AZURE APP SERVICE RECOMMENDATIONS & NOTIFICATIONS ====="
echo "App Service: $APP_SERVICE_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Time Period: $TIME_PERIOD_DAYS days"
echo "Analysis Period: $start_time to $end_time"
echo "=============================================================="

# Get the resource ID of the App Service
if ! resource_id=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then
    echo "Error: App Service $APP_SERVICE_NAME not found in resource group $AZ_RESOURCE_GROUP."
    recommendations_json=$(echo "$recommendations_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` Not Found" \
        --arg details "Could not find App Service $APP_SERVICE_NAME in resource group $AZ_RESOURCE_GROUP" \
        --arg severity "1" \
        '.recommendations += [{"title": $title, "details": $details, "severity": ($severity | tonumber)}]')
    echo "$recommendations_json" > "$OUTPUT_FILE"
    exit 0
fi

# Generate portal URLs for easy access
portal_base_url="https://portal.azure.com/#@$tenant_id"
resource_portal_url="$portal_base_url/resource$resource_id"
advisor_url="$portal_base_url/blade/Microsoft_Azure_Expert/AdvisorMenuBlade/overview"
service_health_url="$portal_base_url/blade/Microsoft_Azure_Health/AzureHealthBrowseBlade/serviceIssues"
security_center_url="$portal_base_url/blade/Microsoft_Azure_Security/SecurityMenuBlade/0"

echo "🔗 Azure Portal Links:"
echo "   App Service: $resource_portal_url/overview"
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
    echo "📊 Found $advisor_count Azure Advisor recommendations for this App Service"
    
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
        portalUrl: "'"$advisor_url"'"
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
    echo "✅ No Azure Advisor recommendations found for this App Service"
fi

echo ""

# 2. FETCH SERVICE HEALTH NOTIFICATIONS
echo "===== FETCHING SERVICE HEALTH NOTIFICATIONS ====="
echo "Checking for Azure Service Health notifications..."

# Get service health events for the region and subscription
service_health_events=$(az rest --method get --url "https://management.azure.com/subscriptions/$subscription_id/providers/Microsoft.ResourceHealth/events?api-version=2022-10-01&\$filter=eventType eq 'ServiceIssue' and lastUpdateTime ge '$start_time'" --query "value[?contains(affectedServices[].serviceName, 'App Service')]" -o json 2>/dev/null || echo "[]")

if [[ -n "$service_health_events" && "$service_health_events" != "[]" ]]; then
    service_health_count=$(echo "$service_health_events" | jq length)
    echo "📊 Found $service_health_count Service Health events affecting App Service"
    
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
        portalUrl: "'"$service_health_url"'"
    }]')
    
    # Add to service health
    recommendations_json=$(echo "$recommendations_json" | jq \
        --argjson health "$processed_service_health" \
        '.service_health += $health')
    
    echo "   📋 Service Health events added to report"
else
    echo "✅ No Service Health events found affecting App Service"
fi

echo ""

# 3. FETCH SECURITY CENTER RECOMMENDATIONS
echo "===== FETCHING SECURITY CENTER RECOMMENDATIONS ====="
echo "Checking for Azure Security Center recommendations..."

# Get security assessments for the App Service
security_assessments=$(az security assessment list --query "[?resourceDetails.id == '$resource_id']" -o json 2>/dev/null || echo "[]")

if [[ -n "$security_assessments" && "$security_assessments" != "[]" ]]; then
    security_count=$(echo "$security_assessments" | jq length)
    echo "📊 Found $security_count Security Center assessments for this App Service"
    
    # Process security assessments
    processed_security=$(echo "$security_assessments" | jq -c '[.[] | {
        id: .id,
        displayName: .displayName,
        description: .metadata.description,
        severity: .metadata.severity,
        status: .status.code,
        categories: .metadata.categories,
        resourceType: .resourceDetails.resourceType,
        lastAssessed: .status.firstEvaluationDate,
        recommendationType: "Security Center",
        portalUrl: "'"$security_center_url"'"
    }]')
    
    # Add to security advisories
    recommendations_json=$(echo "$recommendations_json" | jq \
        --argjson security "$processed_security" \
        '.security_advisories += $security')
    
    echo "   🔒 Security assessments added to report"
else
    echo "✅ No Security Center assessments found for this App Service"
fi

echo ""

# 4. FETCH PERFORMANCE INSIGHTS
echo "===== FETCHING PERFORMANCE INSIGHTS ====="
echo "Checking for performance-related insights..."

# Get current App Service plan details for performance insights
app_service_plan_id=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "serverFarmId" -o tsv 2>/dev/null)

if [[ -n "$app_service_plan_id" ]]; then
    plan_details=$(az appservice plan show --ids "$app_service_plan_id" -o json 2>/dev/null)
    
    if [[ -n "$plan_details" && "$plan_details" != "null" ]]; then
        plan_name=$(echo "$plan_details" | jq -r '.name')
        plan_sku=$(echo "$plan_details" | jq -r '.sku.name')
        plan_tier=$(echo "$plan_details" | jq -r '.sku.tier')
        plan_capacity=$(echo "$plan_details" | jq -r '.sku.capacity')
        
        echo "📊 App Service Plan: $plan_name ($plan_sku - $plan_tier)"
        echo "   Capacity: $plan_capacity instances"
        
        # Create performance insights based on plan details
        performance_insights='[]'
        
        # Check for Free/Shared tiers
        if [[ "$plan_tier" == "Free" || "$plan_tier" == "Shared" ]]; then
            insight='{
                "title": "Consider upgrading from Free/Shared tier",
                "description": "Free and Shared tiers have significant limitations including CPU quotas, no custom domains, and limited scaling options.",
                "severity": "Medium",
                "category": "Performance",
                "recommendation": "Upgrade to Basic or Standard tier for production workloads",
                "recommendationType": "Performance Insight"
            }'
            performance_insights=$(echo "$performance_insights" | jq --argjson insight "$insight" '. + [$insight]')
        fi
        
        # Check for Basic tier with single instance
        if [[ "$plan_tier" == "Basic" && "$plan_capacity" == "1" ]]; then
            insight='{
                "title": "Single instance in Basic tier",
                "description": "Running a single instance provides no redundancy and may impact availability during maintenance.",
                "severity": "Medium",
                "category": "Availability",
                "recommendation": "Scale to multiple instances or upgrade to Standard tier for SLA coverage",
                "recommendationType": "Performance Insight"
            }'
            performance_insights=$(echo "$performance_insights" | jq --argjson insight "$insight" '. + [$insight]')
        fi
        
        # Add performance insights to recommendations
        if [[ $(echo "$performance_insights" | jq length) -gt 0 ]]; then
            recommendations_json=$(echo "$recommendations_json" | jq \
                --argjson insights "$performance_insights" \
                '.performance_insights += $insights')
            echo "   💡 Performance insights added to report"
        fi
    fi
fi

echo ""

# 5. FETCH COST OPTIMIZATION RECOMMENDATIONS
echo "===== FETCHING COST OPTIMIZATION INSIGHTS ====="
echo "Checking for cost optimization opportunities..."

# Get cost-related insights from the App Service plan
if [[ -n "$plan_details" ]]; then
    cost_insights='[]'
    
    # Check for potentially oversized plans
    if [[ "$plan_tier" == "Premium" || "$plan_tier" == "PremiumV2" || "$plan_tier" == "PremiumV3" ]]; then
        insight='{
            "title": "Review Premium tier usage",
            "description": "Premium tiers offer advanced features but may be costlier than necessary for some workloads.",
            "severity": "Low",
            "category": "Cost",
            "recommendation": "Review CPU and memory utilization to ensure Premium tier features are being utilized",
            "recommendationType": "Cost Optimization"
        }'
        cost_insights=$(echo "$cost_insights" | jq --argjson insight "$insight" '. + [$insight]')
    fi
    
    # Check for multiple instances in development environments
    if [[ "$plan_capacity" -gt 1 ]]; then
        insight='{
            "title": "Multiple instances detected",
            "description": "Running multiple instances increases costs. Verify if this is necessary for your workload.",
            "severity": "Low",
            "category": "Cost",
            "recommendation": "For development/testing environments, consider scaling down to single instance",
            "recommendationType": "Cost Optimization"
        }'
        cost_insights=$(echo "$cost_insights" | jq --argjson insight "$insight" '. + [$insight]')
    fi
    
    # Add cost insights to recommendations
    if [[ $(echo "$cost_insights" | jq length) -gt 0 ]]; then
        recommendations_json=$(echo "$recommendations_json" | jq \
            --argjson insights "$cost_insights" \
            '.cost_optimization += $insights')
        echo "   💰 Cost optimization insights added to report"
    fi
fi

echo ""

# 6. GENERATE SUMMARY
echo "===== GENERATING SUMMARY ====="

# Count recommendations by category
total_recommendations=$(echo "$recommendations_json" | jq '.recommendations | length')
total_service_health=$(echo "$recommendations_json" | jq '.service_health | length')
total_security=$(echo "$recommendations_json" | jq '.security_advisories | length')
total_performance=$(echo "$recommendations_json" | jq '.performance_insights | length')
total_cost=$(echo "$recommendations_json" | jq '.cost_optimization | length')

total_all=$((total_recommendations + total_service_health + total_security + total_performance + total_cost))

echo "📊 Summary:"
echo "   Total Recommendations: $total_all"
echo "   - Azure Advisor: $total_recommendations"
echo "   - Service Health: $total_service_health"
echo "   - Security: $total_security"
echo "   - Performance: $total_performance"
echo "   - Cost Optimization: $total_cost"

# Update summary in JSON
recommendations_json=$(echo "$recommendations_json" | jq \
    --arg total_all "$total_all" \
    --arg total_recommendations "$total_recommendations" \
    --arg total_service_health "$total_service_health" \
    --arg total_security "$total_security" \
    --arg total_performance "$total_performance" \
    --arg total_cost "$total_cost" \
    --arg checked_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg app_service "$APP_SERVICE_NAME" \
    --arg resource_group "$AZ_RESOURCE_GROUP" \
    '.summary = {
        "total_recommendations": ($total_all | tonumber),
        "azure_advisor_count": ($total_recommendations | tonumber),
        "service_health_count": ($total_service_health | tonumber),
        "security_advisories_count": ($total_security | tonumber),
        "performance_insights_count": ($total_performance | tonumber),
        "cost_optimization_count": ($total_cost | tonumber),
        "app_service_name": $app_service,
        "resource_group": $resource_group,
        "checked_at": $checked_at,
        "analysis_period_days": '"$TIME_PERIOD_DAYS"',
        "portal_links": {
            "app_service": "'"$resource_portal_url"'/overview",
            "azure_advisor": "'"$advisor_url"'",
            "service_health": "'"$service_health_url"'",
            "security_center": "'"$security_center_url"'"
        }
    }')

# Save the results
echo "$recommendations_json" > "$OUTPUT_FILE"

echo ""
echo "===== RECOMMENDATIONS SUMMARY ====="
if [[ "$total_all" -gt 0 ]]; then
    echo "🔍 Found $total_all recommendations and notifications!"
    echo ""
    echo "🔗 Quick Access Links:"
    echo "   📊 Azure Advisor: $advisor_url"
    echo "   🏥 Service Health: $service_health_url"
    echo "   🔒 Security Center: $security_center_url"
    echo "   📱 App Service: $resource_portal_url/overview"
    echo ""
    echo "📋 Review the detailed recommendations in: $OUTPUT_FILE"
else
    echo "✅ No recommendations or notifications found - your App Service looks good!"
fi

echo ""
echo "Recommendations and notifications analysis completed successfully."
echo "Results saved to $OUTPUT_FILE" 