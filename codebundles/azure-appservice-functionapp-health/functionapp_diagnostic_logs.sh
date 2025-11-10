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
RW_LOOKBACK_WINDOW=${RW_LOOKBACK_WINDOW:-60}

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
echo "Time Period: Last $RW_LOOKBACK_WINDOW minutes"
echo ""

# Get the function app resource ID with timeout
FUNCTION_APP_ID=$(timeout 30 az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null)
if [[ -z "$FUNCTION_APP_ID" ]]; then
    echo "❌ ERROR: Could not retrieve Function App ID for $FUNCTION_APP_NAME"
    exit 1
fi

# Get subscription name from environment variable
SUBSCRIPTION_NAME="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Calculate time range for logs
END_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
START_TIME=$(date -u -d "$RW_LOOKBACK_WINDOW minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "⏰ Time range: $START_TIME to $END_TIME"
echo "📋 Subscription: $SUBSCRIPTION_NAME"
echo ""

# Initialize issues array
ISSUES=()

# Check for diagnostic settings with timeout
echo "📋 Checking diagnostic settings..."
DIAGNOSTIC_SETTINGS=$(timeout 30 az monitor diagnostic-settings list --resource "$FUNCTION_APP_ID" --query "[].{name: name, storageAccountId: storageAccountId, logAnalyticsWorkspaceId: logAnalyticsWorkspaceId, eventHubAuthorizationRuleId: eventHubAuthorizationRuleId}" -o json 2>/dev/null)

if [[ -z "$DIAGNOSTIC_SETTINGS" || "$DIAGNOSTIC_SETTINGS" == "[]" ]]; then
    echo "⚠️  No diagnostic settings found for Function App '$FUNCTION_APP_NAME'"
    echo "   Diagnostic logs are not configured. Consider enabling them for better monitoring."
    
    # Create informational issue about missing diagnostic settings
    ISSUES+=("{\"title\":\"Function App \`$FUNCTION_APP_NAME\` in subscription \`$SUBSCRIPTION_NAME\` has no diagnostic settings configured\",\"severity\":4,\"next_step\":\"Consider enabling diagnostic settings for better monitoring and troubleshooting\",\"details\":\"No diagnostic settings found for Function App '$FUNCTION_APP_NAME' in subscription '$SUBSCRIPTION_NAME'. Diagnostic logs can provide valuable information for troubleshooting issues.\"}")
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
        
        # If Log Analytics is configured, try to query it with timeout
        if [[ "$log_analytics" != "Not configured" ]]; then
            echo "    🔍 Querying Log Analytics workspace..."
            
            # Extract workspace ID from the full resource ID
            workspace_id=$(echo "$log_analytics" | sed 's|.*/workspaces/||')
            
            # Simplified query for function app logs with timeout
            log_query="AzureDiagnostics | where ResourceId == \"$FUNCTION_APP_ID\" | where TimeGenerated >= datetime(\"$START_TIME\") and TimeGenerated <= datetime(\"$END_TIME\") | summarize count() by Category, Level | limit 10"
            
            echo "    Query: $log_query"
            
            # Try to execute the query with timeout
            log_results=$(timeout 45 az monitor log-analytics query --workspace "$workspace_id" --analytics-query "$log_query" -o json 2>/dev/null || echo "[]")
            
            if [[ "$log_results" != "[]" ]]; then
                echo "    ✅ Found log entries in Log Analytics"
                echo "$log_results" | jq -r '.[] | "      \(.Category): \(.Level) (\(.count_) entries)"'
                
                # Check for error-level logs with timeout
                error_logs=$(timeout 45 az monitor log-analytics query --workspace "$workspace_customer_id" --analytics-query "FunctionAppLogs | where TimeGenerated >= datetime(\"$START_TIME\") and TimeGenerated <= datetime(\"$END_TIME\") | where Level == \"Error\" | summarize count(), LastSeen = max(TimeGenerated) by Category | limit 5" -o json 2>/dev/null || echo "[]")
                
                if [[ $(echo "$error_logs" | jq length) -gt 0 ]]; then
                    echo "    ⚠️  Found error logs in Log Analytics"
                    echo "$error_logs" | jq -r '.[] | "      \(.Category): \(.count_) errors"'
                    
                    # Create issue for error logs
                    error_details=$(echo "$error_logs" | jq -r '.[] | "- \(.Category): \(.count_) errors" | join("\n")')
                    observed_at=$(echo "$error_logs" | jq -r '[.[] | .LastSeen] | max')
                    ISSUES+=("{\"title\":\"Function App \`$FUNCTION_APP_NAME\` in subscription \`$SUBSCRIPTION_NAME\` has error logs in Log Analytics\",\"severity\":2,\"next_step\":\"Review error logs in Log Analytics workspace\",\"details\":\"Error logs found in Log Analytics workspace: $workspace_id for Function App '$FUNCTION_APP_NAME' in subscription '$SUBSCRIPTION_NAME'\\n\\n$error_details\",\"observed_at\":\"$observed_at\"}")
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

# Check for Application Insights if available with timeout
echo ""
echo "🔍 Checking for Application Insights..."
APP_INSIGHTS_ID=$(timeout 30 az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "tags.\"hidden-link: /app-insights-resource-id\"" -o tsv 2>/dev/null)

if [[ -n "$APP_INSIGHTS_ID" && "$APP_INSIGHTS_ID" != "None" ]]; then
    echo "✅ Application Insights found: $APP_INSIGHTS_ID"
    
    # Extract App Insights name from the resource ID
    app_insights_name=$(echo "$APP_INSIGHTS_ID" | sed 's|.*/components/||')
    
    # First, verify that Application Insights is actually accessible and working
    echo "🔍 Verifying Application Insights accessibility..."
    test_query="requests | where timestamp > ago(1h) | limit 1"
    test_result=$(timeout 30 az monitor app-insights query --app "$app_insights_name" --analytics-query "$test_query" -o json 2>/dev/null || echo "ERROR")
    
    if [[ "$test_result" == "ERROR" || "$test_result" == "[]" || "$test_result" == "" ]]; then
        echo "⚠️  Application Insights found but not accessible or not collecting data"
        echo "   This could indicate Application Insights is not properly configured or not receiving data"
        ISSUES+=("{\"title\":\"Function App \`$FUNCTION_APP_NAME\` in subscription \`$SUBSCRIPTION_NAME\` has Application Insights but it's not accessible\",\"severity\":3,\"next_step\":\"Verify Application Insights configuration and data collection for \`$FUNCTION_APP_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\`\",\"details\":\"Application Insights resource found: $app_insights_name for Function App '$FUNCTION_APP_NAME' in subscription '$SUBSCRIPTION_NAME', but queries are not returning data. This may indicate the service is not properly configured or not receiving telemetry data.\"}")
    else
        # Application Insights is working, now check for actual issues
        echo "✅ Application Insights is accessible and collecting data"
        
        # Try to query Application Insights for recent exceptions with timeout
        echo "🔍 Querying Application Insights for recent exceptions..."
        
        # Simplified query for exceptions in the last time period
        exceptions_query="exceptions | where timestamp >= datetime(\"$START_TIME\") and timestamp <= datetime(\"$END_TIME\") | summarize count(), LastSeen = max(timestamp) by type, severityLevel | limit 5"
        
        exceptions=$(timeout 45 az monitor app-insights query --app "$app_insights_name" --analytics-query "$exceptions_query" -o json 2>/dev/null || echo "[]")
        
        # Validate JSON response and check if it actually contains data
        if [[ "$exceptions" != "[]" && "$exceptions" != "" ]]; then
            if echo "$exceptions" | jq empty >/dev/null 2>&1; then
                # Check if the result actually contains exception data (not just empty tables)
                exception_count=$(echo "$exceptions" | jq 'length' 2>/dev/null || echo "0")
                if [[ "$exception_count" -gt 0 ]]; then
                    echo "⚠️  Found exceptions in Application Insights:"
                    echo "$exceptions" | jq -r '.[] | "  - \(.type): \(.severityLevel) (\(.count_) occurrences)"' 2>/dev/null || echo "  - Unable to parse exception details"
                    
                    # Create issue for exceptions
                    exception_details=$(echo "$exceptions" | jq -r '.[] | "- \(.type): \(.severityLevel) (\(.count_) occurrences)" | join("\n")' 2>/dev/null || echo "Unable to parse exception details")
                    observed_at=$(echo "$exceptions" | jq -r '[.[] | .LastSeen] | max')
                    ISSUES+=("{\"title\":\"Function App \`$FUNCTION_APP_NAME\` in subscription \`$SUBSCRIPTION_NAME\` has exceptions in Application Insights\",\"severity\":2,\"next_step\":\"Review exceptions in Application Insights\",\"details\":\"Exceptions found in Application Insights: $app_insights_name for Function App '$FUNCTION_APP_NAME' in subscription '$SUBSCRIPTION_NAME'\\n\\n$exception_details\",\"observed_at\":\"$observed_at\"}")
                else
                    echo "✅ No recent exceptions found in Application Insights"
                fi
            else
                echo "⚠️  Application Insights query returned invalid JSON for exceptions"
                echo "   This may indicate a configuration issue with Application Insights"
            fi
        else
            echo "✅ No recent exceptions found in Application Insights"
        fi
        
        # Query for failed requests with timeout
        echo "🔍 Querying Application Insights for failed requests..."
        
        # Simplified query for failed requests
        failed_requests_query="requests | where timestamp >= datetime(\"$START_TIME\") and timestamp <= datetime(\"$END_TIME\") | where success == false | summarize count(), LastSeen = max(timestamp) by name, resultCode | limit 5"
        
        failed_requests=$(timeout 45 az monitor app-insights query --app "$app_insights_name" --analytics-query "$failed_requests_query" -o json 2>/dev/null || echo "[]")
        
        # Validate JSON response and check if it actually contains data
        if [[ "$failed_requests" != "[]" && "$failed_requests" != "" ]]; then
            if echo "$failed_requests" | jq empty >/dev/null 2>&1; then
                # Check if the result actually contains failed request data (not just empty tables)
                failed_count=$(echo "$failed_requests" | jq 'length' 2>/dev/null || echo "0")
                if [[ "$failed_count" -gt 0 ]]; then
                    echo "⚠️  Found failed requests in Application Insights:"
                    echo "$failed_requests" | jq -r '.[] | "  - \(.name): HTTP \(.resultCode) (\(.count_) failures)"' 2>/dev/null || echo "  - Unable to parse failed request details"
                    
                    # Create issue for failed requests
                    failed_details=$(echo "$failed_requests" | jq -r '.[] | "- \(.name): HTTP \(.resultCode) (\(.count_) failures)" | join("\n")' 2>/dev/null || echo "Unable to parse failed request details")
                    observed_at=$(echo "$failed_requests" | jq -r '[.[] | .LastSeen] | max')
                    ISSUES+=("{\"title\":\"Function App \`$FUNCTION_APP_NAME\` in subscription \`$SUBSCRIPTION_NAME\` has failed requests in Application Insights\",\"severity\":2,\"next_step\":\"Review failed requests in Application Insights\",\"details\":\"Failed requests found in Application Insights: $app_insights_name for Function App '$FUNCTION_APP_NAME' in subscription '$SUBSCRIPTION_NAME'\\n\\n$failed_details\",\"observed_at\":\"$observed_at\"}")
                else
                    echo "✅ No recent failed requests found in Application Insights"
                fi
            else
                echo "⚠️  Application Insights query returned invalid JSON for failed requests"
                echo "   This may indicate a configuration issue with Application Insights"
            fi
        else
            echo "✅ No recent failed requests found in Application Insights"
        fi
    fi
else
    echo "ℹ️  No Application Insights found for Function App '$FUNCTION_APP_NAME'"
    echo "   Consider enabling Application Insights for better monitoring and error tracking"
    ISSUES+=("{\"title\":\"Function App \`$FUNCTION_APP_NAME\` in subscription \`$SUBSCRIPTION_NAME\` has no Application Insights configured\",\"severity\":4,\"next_step\":\"Enable Application Insights for \`$FUNCTION_APP_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$SUBSCRIPTION_NAME\` for better monitoring\",\"details\":\"Application Insights is not configured for Function App '$FUNCTION_APP_NAME' in subscription '$SUBSCRIPTION_NAME'. This limits the ability to monitor application performance and detect errors.\"}")
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
echo "Time Period: Last $RW_LOOKBACK_WINDOW minutes"
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