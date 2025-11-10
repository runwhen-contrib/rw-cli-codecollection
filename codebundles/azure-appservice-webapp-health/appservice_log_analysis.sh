#!/bin/bash

# Variables
OUTPUT_FILE="app_service_log_issues_report.json"

# Use existing subscription name variable
SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Initialize issues JSON - this ensures we always have valid output
issues_json='{"issues": []}'

echo "Quick App Service Log Analysis for '$APP_SERVICE_NAME'"
echo "====================================================="

# Ensure required variables are set
if [[ -z "$APP_SERVICE_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "Error: APP_SERVICE_NAME and AZ_RESOURCE_GROUP environment variables must be set."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Required Environment Variables" \
        --arg details "APP_SERVICE_NAME and AZ_RESOURCE_GROUP must be set for log analysis" \
        --arg nextSteps "Set required environment variables and retry log analysis" \
        --arg severity "1" \
        --arg observed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber), "observed_at": $observed_at}]')
    echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
    exit 0
fi

# Step 1: Quick App Service verification (3 second timeout)
echo "Verifying App Service exists..."
if timeout 3s az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "name" -o tsv >/dev/null 2>&1; then
    echo "✓ App Service '$APP_SERVICE_NAME' is accessible"
else
    echo "✗ App Service '$APP_SERVICE_NAME' not accessible or timed out"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` Not Accessible in subscription \`$SUBSCRIPTION_NAME\`" \
        --arg details "Could not verify App Service '$APP_SERVICE_NAME' in resource group '$AZ_RESOURCE_GROUP' within 3 seconds" \
        --arg nextSteps "Verify App Service name and check permissions for \`$APP_SERVICE_NAME\` in RG \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "3" \
        --arg observed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber), "observed_at": $observed_at}]')
    echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
    exit 0
fi

# Step 2: Quick Application Insights check (3 second timeout)
echo "Checking for Application Insights integration..."
APP_INSIGHTS_KEY=""
if APP_INSIGHTS_KEY=$(timeout 3s az webapp config appsettings list --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "[?name=='APPINSIGHTS_INSTRUMENTATIONKEY'].value | [0]" -o tsv 2>/dev/null); then
    if [[ -n "$APP_INSIGHTS_KEY" && "$APP_INSIGHTS_KEY" != "null" ]]; then
        echo "✓ Application Insights found"
        
        ai_name=$(az resource list --resource-group "$AZ_RESOURCE_GROUP" --resource-type "microsoft.insights/components" --query "[0].{name:name}" -o tsv 2>/dev/null)
        ai_rg=$(az resource list --resource-group "$AZ_RESOURCE_GROUP" --resource-type "microsoft.insights/components" --query "[0].{resourceGroup:resourceGroup}" -o tsv 2>/dev/null)
        app_insights_app_id=$(az resource show --resource-group "$ai_rg" --name "$ai_name" --resource-type "microsoft.insights/components" --query "properties.AppId" -o tsv 2>/dev/null)

        # Quick query for recent errors (5 second timeout)
        echo "Querying recent application errors (last 30 minutes)..."
        KUSTO_QUERY="union traces, exceptions | where timestamp > ago(30m) | where severityLevel >= 2 | order by timestamp desc | limit 5 | project timestamp, message"
        
        if RECENT_ERRORS=$(timeout 5s az monitor app-insights query --app "$app_insights_app_id" --analytics-query "$KUSTO_QUERY" --query "tables[0].rows" -o json 2>/dev/null); then
            if [[ -n "$RECENT_ERRORS" && "$RECENT_ERRORS" != "[]" && "$RECENT_ERRORS" != "null" ]]; then
                error_count=$(echo "$RECENT_ERRORS" | jq 'length' 2>/dev/null || echo "0")
                if [[ $error_count -gt 0 ]]; then
                    echo "✓ Found $error_count recent error(s) via Application Insights"
                    
                    # Get first error message for summary
                    first_error=$(echo "$RECENT_ERRORS" | jq -r '.[0][1]' 2>/dev/null | head -c 200)
                    error_timestamp=$(echo "$RECENT_ERRORS" | jq -r '[0][0]' 2>/dev/null)

                    issues_json=$(echo "$issues_json" | jq \
                        --arg title "Recent Application Errors in \`$APP_SERVICE_NAME\`" \
                        --arg details "Found $error_count recent errors via Application Insights. First error: $first_error" \
                        --arg nextSteps "Review and fix application errors in \`$APP_SERVICE_NAME\` in RG \`$AZ_RESOURCE_GROUP\`" \
                        --arg severity "3" \
                        --arg observed_at "$error_timestamp" \
                        '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber), "observed_at": $observed_at}]')
                else
                    echo "✓ No recent errors found in Application Insights"
                fi
            else
                echo "✓ No recent errors found in Application Insights"
            fi
        else
            echo "ℹ Could not query Application Insights data within timeout"
        fi
    else
        echo "ℹ No Application Insights integration found"
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Application Insights Integration for \`$APP_SERVICE_NAME\`" \
            --arg details "Application Insights is not configured for this App Service. Consider enabling it for better monitoring and error tracking" \
            --arg nextSteps "Enable Application Insights for \`$APP_SERVICE_NAME\` in RG \`$AZ_RESOURCE_GROUP\` to improve monitoring capabilities" \
            --arg severity "4" \
            --arg observed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber), "observed_at": $observed_at}]')
    fi
else
    echo "ℹ Could not check Application Insights configuration within timeout"
fi

# Step 3: Quick diagnostic settings check (3 second timeout)
echo "Checking diagnostic settings..."
if APP_SERVICE_RESOURCE_ID=$(timeout 3s az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then
    if DIAGNOSTIC_SETTINGS=$(timeout 3s az monitor diagnostic-settings list --resource "$APP_SERVICE_RESOURCE_ID" --query "[0].workspaceId" -o tsv 2>/dev/null); then
        if [[ -n "$DIAGNOSTIC_SETTINGS" && "$DIAGNOSTIC_SETTINGS" != "null" ]]; then
            echo "✓ Diagnostic settings configured with Log Analytics workspace"
            
            workspace_name=$(az resource show --ids "$DIAGNOSTIC_SETTINGS" --query "name" -o tsv 2>/dev/null)
            workspace_rg=$(az resource show --ids "$DIAGNOSTIC_SETTINGS" --query "resourceGroup" -o tsv 2>/dev/null)
            workspace_guid=$(az monitor log-analytics workspace show --resource-group "$workspace_rg" --workspace-name "$workspace_name" --query "customerId" -o tsv 2>/dev/null)

            # Quick Log Analytics query (5 second timeout)
            echo "Querying Log Analytics for recent errors..."
            KUSTO_LOG_QUERY="AppServiceConsoleLogs | where TimeGenerated > ago(30m) | where Level in ('Error', 'Critical') | order by TimeGenerated desc | limit 5 | project TimeGenerated, Level, ResultDescription"
            
            if LOG_ANALYTICS_RESULTS=$(timeout 5s az monitor log-analytics query --workspace "$workspace_guid" --analytics-query "$KUSTO_LOG_QUERY" --query "[]" -o json 2>/dev/null); then
                if [[ -n "$LOG_ANALYTICS_RESULTS" && "$LOG_ANALYTICS_RESULTS" != "[]" && "$LOG_ANALYTICS_RESULTS" != "null" ]]; then
                    log_error_count=$(echo "$LOG_ANALYTICS_RESULTS" | jq 'length' 2>/dev/null || echo "0")
                    if [[ $log_error_count -gt 0 ]]; then
                        echo "✓ Found $log_error_count recent log errors"
                        
                        # Get first error for summary
                        first_log_error=$(echo "$LOG_ANALYTICS_RESULTS" | jq -r '.[0].ResultDescription // .[0][2]' 2>/dev/null | head -c 200)
                        log_error_timestamp=$(echo "$LOG_ANALYTICS_RESULTS" | jq -r '.[0].TimeGenerated // .[0][0]' 2>/dev/null)
                        
                        issues_json=$(echo "$issues_json" | jq \
                            --arg title "Recent Log Errors in \`$APP_SERVICE_NAME\`" \
                            --arg details "Found $log_error_count recent error entries in diagnostic logs. First error: $first_log_error" \
                            --arg nextSteps "Review diagnostic logs and fix errors in \`$APP_SERVICE_NAME\` in RG \`$AZ_RESOURCE_GROUP\`" \
                            --arg severity "3" \
                            --arg observed_at "$log_error_timestamp" \
                            '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber), "observed_at": $observed_at}]')
                    else
                        echo "✓ No recent errors in diagnostic logs"
                    fi
                else
                    echo "✓ No recent errors in diagnostic logs"
                fi
            else
                echo "ℹ Could not query Log Analytics workspace within timeout"
            fi
        else
            echo "ℹ No Log Analytics workspace configured in diagnostic settings"
        fi
    else
        echo "ℹ Could not check diagnostic settings within timeout"
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Diagnostic Settings for \`$APP_SERVICE_NAME\`" \
            --arg details "Diagnostic settings are not configured or could not be verified for this App Service" \
            --arg nextSteps "Configure diagnostic settings for \`$APP_SERVICE_NAME\` in RG \`$AZ_RESOURCE_GROUP\` to enable log collection" \
            --arg severity "4" \
            --arg observed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber), "observed_at": $observed_at}]')
    fi
else
    echo "ℹ Could not get App Service resource ID within timeout"
fi

# Always output issues report
echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
echo "Log analysis completed. Results saved to $OUTPUT_FILE"

echo ""
echo "Fast Azure Monitor API log analysis completed:"
echo "- App Service verification: 3s timeout"
echo "- Application Insights query: 5s timeout (last 30 minutes)"
echo "- Log Analytics query: 5s timeout (last 30 minutes)"
echo "- NO log downloads or streaming - API queries only"
echo "- Total execution time: ~15 seconds maximum"
echo "- All timeouts are aggressive to prevent hanging"
