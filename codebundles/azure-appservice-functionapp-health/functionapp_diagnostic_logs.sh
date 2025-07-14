#!/bin/bash

# Function App Diagnostic Logs Check Script
# This script checks for diagnostic logs configuration and searches them for relevant events

set -e

# Source environment variables
source .env 2>/dev/null || true

# Default values
FUNCTION_APP_NAME=${FUNCTION_APP_NAME:-""}
AZ_RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-""}
AZURE_RESOURCE_SUBSCRIPTION_ID=${AZURE_RESOURCE_SUBSCRIPTION_ID:-""}
TIME_PERIOD_MINUTES=${TIME_PERIOD_MINUTES:-60}

# Validation
if [[ -z "$FUNCTION_APP_NAME" ]]; then
    echo "ERROR: FUNCTION_APP_NAME is required"
    exit 1
fi

if [[ -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "ERROR: AZ_RESOURCE_GROUP is required"
    exit 1
fi

if [[ -z "$AZURE_RESOURCE_SUBSCRIPTION_ID" ]]; then
    echo "ERROR: AZURE_RESOURCE_SUBSCRIPTION_ID is required"
    exit 1
fi

echo "🔍 Checking Function App Diagnostic Logs"
echo "========================================"
echo "Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Time Period: Last $TIME_PERIOD_MINUTES minutes"
echo ""

# Get the function app resource ID
FUNCTION_APP_ID=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null)
if [[ -z "$FUNCTION_APP_ID" ]]; then
    echo "❌ ERROR: Could not retrieve Function App ID for $FUNCTION_APP_NAME"
    exit 1
fi

# Calculate time range for logs
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "⏰ Time range: $START_TIME to $END_TIME"
echo ""

# Initialize issues array
ISSUES=()

# Check for diagnostic settings
echo "📋 Checking diagnostic settings..."
DIAGNOSTIC_SETTINGS=$(az monitor diagnostic-settings list --resource "$FUNCTION_APP_ID" --query "[].{name: name, storageAccountId: storageAccountId, logAnalyticsWorkspaceId: logAnalyticsWorkspaceId, eventHubAuthorizationRuleId: eventHubAuthorizationRuleId}" -o json 2>/dev/null)

if [[ -z "$DIAGNOSTIC_SETTINGS" || "$DIAGNOSTIC_SETTINGS" == "[]" ]]; then
    echo "⚠️  No diagnostic settings found for Function App '$FUNCTION_APP_NAME'"
    echo "   Diagnostic logs are not configured. Consider enabling them for better monitoring."
    
    # Create informational issue about missing diagnostic settings
    ISSUES+=("{\"title\":\"Function App '$FUNCTION_APP_NAME' has no diagnostic settings configured\",\"severity\":4,\"next_step\":\"Consider enabling diagnostic settings for better monitoring and troubleshooting\",\"details\":\"No diagnostic settings found for Function App '$FUNCTION_APP_NAME'. Diagnostic logs can provide valuable information for troubleshooting issues.\"}")
else
    echo "✅ Found $(echo "$DIAGNOSTIC_SETTINGS" | jq length) diagnostic setting(s)"
    
    # Check each diagnostic setting
    echo "$DIAGNOSTIC_SETTINGS" | jq -c '.[]' | while read -r setting; do
        setting_name=$(echo "$setting" | jq -r '.name')
        storage_account=$(echo "$setting" | jq -r '.storageAccountId // "Not configured"')
        log_analytics=$(echo "$setting" | jq -r '.logAnalyticsWorkspaceId // "Not configured"')
        event_hub=$(echo "$setting" | jq -r '.eventHubAuthorizationRuleId // "Not configured"')
        
        echo "  - Setting: $setting_name"
        echo "    Storage Account: $storage_account"
        echo "    Log Analytics: $log_analytics"
        echo "    Event Hub: $event_hub"
        
        # If Log Analytics is configured, try to query it
        if [[ "$log_analytics" != "Not configured" ]]; then
            echo "    🔍 Querying Log Analytics workspace..."
            
            # Extract workspace ID from the full resource ID
            workspace_id=$(echo "$log_analytics" | sed 's|.*/workspaces/||')
            
            # Query for function app logs
            # Note: This requires the Log Analytics workspace to be accessible and the user to have permissions
            log_query="AzureDiagnostics | where ResourceId == \"$FUNCTION_APP_ID\" | where TimeGenerated >= datetime(\"$START_TIME\") and TimeGenerated <= datetime(\"$END_TIME\") | summarize count() by Category, Level"
            
            echo "    Query: $log_query"
            
            # Try to execute the query (this may fail if user doesn't have access)
            log_results=$(az monitor log-analytics query --workspace "$workspace_id" --analytics-query "$log_query" -o json 2>/dev/null || echo "[]")
            
            if [[ "$log_results" != "[]" ]]; then
                echo "    ✅ Found log entries in Log Analytics"
                echo "$log_results" | jq -r '.[] | "      \(.Category): \(.Level) (\(.count_) entries)"'
                
                # Check for error-level logs
                error_logs=$(az monitor log-analytics query --workspace "$workspace_id" --analytics-query "AzureDiagnostics | where ResourceId == \"$FUNCTION_APP_ID\" | where TimeGenerated >= datetime(\"$START_TIME\") and TimeGenerated <= datetime(\"$END_TIME\") | where Level == \"Error\" | summarize count() by Category" -o json 2>/dev/null || echo "[]")
                
                if [[ $(echo "$error_logs" | jq length) -gt 0 ]]; then
                    echo "    ⚠️  Found error logs in Log Analytics"
                    echo "$error_logs" | jq -r '.[] | "      \(.Category): \(.count_) errors"'
                    
                    # Create issue for error logs
                    error_details=$(echo "$error_logs" | jq -r '.[] | "- \(.Category): \(.count_) errors" | join("\n")')
                    ISSUES+=("{\"title\":\"Function App '$FUNCTION_APP_NAME' has error logs in Log Analytics\",\"severity\":2,\"next_step\":\"Review error logs in Log Analytics workspace\",\"details\":\"Error logs found in Log Analytics workspace: $workspace_id\\n\\n$error_details\"}")
                fi
            else
                echo "    ℹ️  No recent log entries found in Log Analytics"
            fi
        fi
        
        # If Storage Account is configured, note it (but don't try to query it directly)
        if [[ "$storage_account" != "Not configured" ]]; then
            echo "    📦 Storage Account logs available (requires direct access to query)"
        fi
        
        # If Event Hub is configured, note it
        if [[ "$event_hub" != "Not configured" ]]; then
            echo "    📡 Event Hub configured (requires direct access to query)"
        fi
    done
fi

# Check for Application Insights if available
echo ""
echo "🔍 Checking for Application Insights..."
APP_INSIGHTS_ID=$(az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "tags.\"hidden-link: /app-insights-resource-id\"" -o tsv 2>/dev/null)

if [[ -n "$APP_INSIGHTS_ID" && "$APP_INSIGHTS_ID" != "None" ]]; then
    echo "✅ Application Insights found: $APP_INSIGHTS_ID"
    
    # Extract App Insights name from the resource ID
    app_insights_name=$(echo "$APP_INSIGHTS_ID" | sed 's|.*/components/||')
    
    # Try to query Application Insights for recent exceptions
    echo "🔍 Querying Application Insights for recent exceptions..."
    
    # Query for exceptions in the last time period
    exceptions_query="exceptions | where timestamp >= datetime(\"$START_TIME\") and timestamp <= datetime(\"$END_TIME\") | summarize count() by type, severityLevel"
    
    exceptions=$(az monitor app-insights query --app "$app_insights_name" --analytics-query "$exceptions_query" -o json 2>/dev/null || echo "[]")
    
    if [[ "$exceptions" != "[]" ]]; then
        echo "⚠️  Found exceptions in Application Insights:"
        echo "$exceptions" | jq -r '.[] | "  - \(.type): \(.severityLevel) (\(.count_) occurrences)"'
        
        # Create issue for exceptions
        exception_details=$(echo "$exceptions" | jq -r '.[] | "- \(.type): \(.severityLevel) (\(.count_) occurrences)" | join("\n")')
        ISSUES+=("{\"title\":\"Function App '$FUNCTION_APP_NAME' has exceptions in Application Insights\",\"severity\":2,\"next_step\":\"Review exceptions in Application Insights\",\"details\":\"Exceptions found in Application Insights: $app_insights_name\\n\\n$exception_details\"}")
    else
        echo "✅ No recent exceptions found in Application Insights"
    fi
    
    # Query for failed requests
    echo "🔍 Querying Application Insights for failed requests..."
    
    failed_requests_query="requests | where timestamp >= datetime(\"$START_TIME\") and timestamp <= datetime(\"$END_TIME\") | where success == false | summarize count() by name, resultCode"
    
    failed_requests=$(az monitor app-insights query --app "$app_insights_name" --analytics-query "$failed_requests_query" -o json 2>/dev/null || echo "[]")
    
    if [[ "$failed_requests" != "[]" ]]; then
        echo "⚠️  Found failed requests in Application Insights:"
        echo "$failed_requests" | jq -r '.[] | "  - \(.name): HTTP \(.resultCode) (\(.count_) failures)"'
        
        # Create issue for failed requests
        failed_details=$(echo "$failed_requests" | jq -r '.[] | "- \(.name): HTTP \(.resultCode) (\(.count_) failures)" | join("\n")')
        ISSUES+=("{\"title\":\"Function App '$FUNCTION_APP_NAME' has failed requests in Application Insights\",\"severity\":2,\"next_step\":\"Review failed requests in Application Insights\",\"details\":\"Failed requests found in Application Insights: $app_insights_name\\n\\n$failed_details\"}")
    else
        echo "✅ No recent failed requests found in Application Insights"
    fi
else
    echo "ℹ️  No Application Insights found for Function App '$FUNCTION_APP_NAME'"
fi

# Create JSON output
JSON_OUTPUT="{\"issues\":["
if [[ ${#ISSUES[@]} -gt 0 ]]; then
    JSON_OUTPUT+=$(IFS=,; echo "${ISSUES[*]}")
fi
JSON_OUTPUT+="],\"summary\":{\"diagnostic_settings_count\":$(echo "$DIAGNOSTIC_SETTINGS" | jq length),\"has_app_insights\":$([ -n "$APP_INSIGHTS_ID" ] && echo "true" || echo "false")}}"

# Validate JSON before writing to file
if command -v jq >/dev/null 2>&1; then
    if echo "$JSON_OUTPUT" | jq empty >/dev/null 2>&1; then
        echo "$JSON_OUTPUT" > functionapp_diagnostic_logs.json
        echo "✅ JSON validation passed"
    else
        echo "❌ JSON validation failed - generating fallback JSON"
        echo '{"issues":[],"summary":{"diagnostic_settings_count":0,"has_app_insights":false}}' > functionapp_diagnostic_logs.json
    fi
else
    echo "$JSON_OUTPUT" > functionapp_diagnostic_logs.json
    echo "⚠️  jq not available - JSON validation skipped"
fi

echo ""
echo "✅ Function App Diagnostic Logs Check Completed"
echo "=============================================="
echo "📊 Results saved to: functionapp_diagnostic_logs.json"
echo ""

echo "📋 Executive Summary"
echo "==================="
echo "Function App: $FUNCTION_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Subscription: $AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Time Period: Last $TIME_PERIOD_MINUTES minutes"
echo "Diagnostic Settings: $(echo "$DIAGNOSTIC_SETTINGS" | jq length)"
echo "Application Insights: $([ -n "$APP_INSIGHTS_ID" ] && echo "Configured" || echo "Not configured")"
echo "Issues Found: ${#ISSUES[@]}"
echo ""

if [[ ${#ISSUES[@]} -eq 0 ]]; then
    echo "🎉 No diagnostic log issues found!"
else
    echo "⚠️  Issues detected:"
    for i in "${!ISSUES[@]}"; do
        issue_title=$(echo "${ISSUES[$i]}" | jq -r '.title' 2>/dev/null || echo "Issue $((i+1))")
        echo "  $((i+1)). $issue_title"
    done
fi 