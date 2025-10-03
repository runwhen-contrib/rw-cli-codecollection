#!/bin/bash

# App Service Diagnostic Logs Analysis Script
# This script checks diagnostic settings, queries Log Analytics and Application Insights for errors,
# and raises structured issues for detected problems.

# Environment variables
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

OUTPUT_FILE="app_service_diagnostic_issues.json"
SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-$(az account show --query "name" -o tsv 2>/dev/null || echo "Unknown")}"

# Initialize issues JSON
issues_json='{"issues": []}'

echo "App Service Diagnostic Logs Analysis for '$APP_SERVICE_NAME' in '$AZ_RESOURCE_GROUP'"
echo "Subscription: $SUBSCRIPTION_NAME"
echo "====================================================="

# Validate required environment variables
if [[ -z "$APP_SERVICE_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: APP_SERVICE_NAME and AZ_RESOURCE_GROUP environment variables must be set. (detected at $log_timestamp)"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Required Environment Variables for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
        --arg details "APP_SERVICE_NAME and AZ_RESOURCE_GROUP must be set for diagnostic log analysis" \
        --arg nextSteps "Set required environment variables and retry diagnostic log analysis" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
    echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
    exit 0
fi

# Get App Service resource ID
echo "Getting App Service resource ID..."
if ! resource_id=$(timeout 10s az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: Could not retrieve App Service resource ID (detected at $log_timestamp)"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` Not Accessible in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
        --arg details "Could not retrieve resource ID for App Service \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`. Service may not exist or access may be restricted." \
        --arg nextSteps "Verify App Service \`$APP_SERVICE_NAME\` exists in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\` and check access permissions" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
    echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
    exit 0
fi

echo "Resource ID: $resource_id"

# Check diagnostic settings
echo "Checking diagnostic settings..."
if ! diagnostic_settings=$(timeout 10s az monitor diagnostic-settings list --resource "$resource_id" --query "value[0]" -o json 2>/dev/null); then
    echo "Warning: Could not retrieve diagnostic settings"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Diagnostic Settings Not Configured for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
        --arg details "Diagnostic settings are not configured for App Service \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`. This limits monitoring capabilities." \
        --arg nextSteps "Configure diagnostic settings for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\` to enable comprehensive logging and monitoring" \
        --arg severity "3" \
        '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
else
    if [[ "$diagnostic_settings" == "null" || "$diagnostic_settings" == "[]" ]]; then
        echo "No diagnostic settings found"
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Diagnostic Settings Not Configured for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
            --arg details "Diagnostic settings are not configured for App Service \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`. This limits monitoring capabilities." \
            --arg nextSteps "Configure diagnostic settings for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\` to enable comprehensive logging and monitoring" \
            --arg severity "3" \
            '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
    else
        echo "Diagnostic settings found"
        workspace_id=$(echo "$diagnostic_settings" | jq -r '.workspaceId // empty')
        if [[ -n "$workspace_id" && "$workspace_id" != "null" ]]; then
            echo "Log Analytics workspace: $workspace_id"
            
            # Query Log Analytics for errors (last 2 hours)
            echo "Querying Log Analytics for recent errors..."
            kusto_query="AppServiceConsoleLogs | where TimeGenerated > ago(2h) | where Level in ('Error', 'Critical') | order by TimeGenerated desc | limit 10 | project TimeGenerated, Level, ResultDescription"
            
            if log_analytics_results=$(timeout 15s az monitor log-analytics query --workspace "$workspace_id" --analytics-query "$kusto_query" --query "tables[0].rows" -o json 2>/dev/null); then
                if [[ -n "$log_analytics_results" && "$log_analytics_results" != "[]" && "$log_analytics_results" != "null" ]]; then
                    error_count=$(echo "$log_analytics_results" | jq 'length' 2>/dev/null || echo "0")
                    if [[ $error_count -gt 0 ]]; then
                        echo "Found $error_count error(s) in Log Analytics"
                        
                        # Get first error for summary
                        first_error=$(echo "$log_analytics_results" | jq -r '.[0][2]' 2>/dev/null | head -c 200)
                        
                        issues_json=$(echo "$issues_json" | jq \
                            --arg title "Recent Log Errors in \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
                            --arg details "Found $error_count recent error entries in diagnostic logs for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`. First error: $first_error" \
                            --arg nextSteps "Review diagnostic logs and fix errors in \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`" \
                            --arg severity "2" \
                            '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
                    else
                        echo "No recent errors found in Log Analytics"
                    fi
                else
                    echo "No recent errors found in Log Analytics"
                fi
            else
                echo "Warning: Could not query Log Analytics workspace"
            fi
        else
            echo "No Log Analytics workspace configured"
            issues_json=$(echo "$issues_json" | jq \
                --arg title "No Log Analytics Workspace for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
                --arg details "Diagnostic settings exist but no Log Analytics workspace is configured for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`" \
                --arg nextSteps "Configure Log Analytics workspace in diagnostic settings for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`" \
                --arg severity "3" \
                '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
        fi
    fi
fi

# Check Application Insights
echo "Checking Application Insights integration..."
if ! app_insights_key=$(timeout 10s az webapp config appsettings list --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "[?name=='APPINSIGHTS_INSTRUMENTATIONKEY'].value | [0]" -o tsv 2>/dev/null); then
    echo "Warning: Could not check Application Insights configuration"
else
    if [[ -n "$app_insights_key" && "$app_insights_key" != "null" ]]; then
        echo "Application Insights found"
        
        # Query Application Insights for errors (last 2 hours)
        echo "Querying Application Insights for recent errors..."
        kusto_query="union traces, exceptions | where timestamp > ago(2h) | where severityLevel >= 2 | order by timestamp desc | limit 10 | project timestamp, message"
        
        if app_insights_results=$(timeout 15s az monitor app-insights query --app "$app_insights_key" --analytics-query "$kusto_query" --query "tables[0].rows" -o json 2>/dev/null); then
            if [[ -n "$app_insights_results" && "$app_insights_results" != "[]" && "$app_insights_results" != "null" ]]; then
                error_count=$(echo "$app_insights_results" | jq 'length' 2>/dev/null || echo "0")
                if [[ $error_count -gt 0 ]]; then
                    echo "Found $error_count error(s) in Application Insights"
                    
                    # Get first error for summary
                    first_error=$(echo "$app_insights_results" | jq -r '.[0][1]' 2>/dev/null | head -c 200)
                    
                    issues_json=$(echo "$issues_json" | jq \
                        --arg title "Recent Application Errors in \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
                        --arg details "Found $error_count recent errors via Application Insights for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`. First error: $first_error" \
                        --arg nextSteps "Review and fix application errors in \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`" \
                        --arg severity "2" \
                        '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
                else
                    echo "No recent errors found in Application Insights"
                fi
            else
                echo "No recent errors found in Application Insights"
            fi
        else
            echo "Warning: Could not query Application Insights data"
        fi
    else
        echo "No Application Insights integration found"
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Application Insights Integration for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
            --arg details "Application Insights is not configured for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`. Consider enabling it for better monitoring and error tracking." \
            --arg nextSteps "Enable Application Insights for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\` to improve monitoring capabilities" \
            --arg severity "4" \
            '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
    fi
fi

# Check for failed requests in Application Insights
if [[ -n "$app_insights_key" && "$app_insights_key" != "null" ]]; then
    echo "Checking for failed requests in Application Insights..."
    kusto_query="requests | where timestamp > ago(2h) | where success == false | order by timestamp desc | limit 10 | project timestamp, name, resultCode, duration"
    
    if failed_requests=$(timeout 15s az monitor app-insights query --app "$app_insights_key" --analytics-query "$kusto_query" --query "tables[0].rows" -o json 2>/dev/null); then
        if [[ -n "$failed_requests" && "$failed_requests" != "[]" && "$failed_requests" != "null" ]]; then
            failed_count=$(echo "$failed_requests" | jq 'length' 2>/dev/null || echo "0")
            if [[ $failed_count -gt 0 ]]; then
                echo "Found $failed_count failed request(s) in Application Insights"
                
                # Get first failed request for summary
                first_failed=$(echo "$failed_requests" | jq -r '.[0][1]' 2>/dev/null | head -c 200)
                
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Recent Failed Requests in \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$SUBSCRIPTION_NAME\`)" \
                    --arg details "Found $failed_count recent failed requests via Application Insights for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`. First failed request: $first_failed" \
                    --arg nextSteps "Investigate and fix failed requests in \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`" \
                    --arg severity "2" \
                    '.issues += [{"title": $title, "details": $details, "next_steps": $nextSteps, "severity": ($severity | tonumber)}]')
            else
                echo "No recent failed requests found in Application Insights"
            fi
        else
            echo "No recent failed requests found in Application Insights"
        fi
    else
        echo "Warning: Could not query failed requests from Application Insights"
    fi
fi

# Save results
echo "$issues_json" | jq '.' > "$OUTPUT_FILE"

# Generate summary
echo "App Service Diagnostic Logs Summary" > "app_service_diagnostic_summary.txt"
echo "===================================" >> "app_service_diagnostic_summary.txt"
echo "App Service: $APP_SERVICE_NAME" >> "app_service_diagnostic_summary.txt"
echo "Resource Group: $AZ_RESOURCE_GROUP" >> "app_service_diagnostic_summary.txt"
echo "Subscription: $SUBSCRIPTION_NAME" >> "app_service_diagnostic_summary.txt"
echo "Analysis Time: $(date -u)" >> "app_service_diagnostic_summary.txt"
echo "" >> "app_service_diagnostic_summary.txt"

issue_count=$(echo "$issues_json" | jq '.issues | length')
echo "Issues Detected: $issue_count" >> "app_service_diagnostic_summary.txt"
echo "" >> "app_service_diagnostic_summary.txt"

if [[ $issue_count -gt 0 ]]; then
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_steps)\n"' >> "app_service_diagnostic_summary.txt"
else
    echo "No issues detected. App Service diagnostic logs appear healthy." >> "app_service_diagnostic_summary.txt"
fi

echo "Diagnostic logs analysis completed. Results saved to $OUTPUT_FILE"
echo "Summary saved to app_service_diagnostic_summary.txt"
