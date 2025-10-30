#!/bin/bash

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

echo "Analyzing logs for Container App: $CONTAINER_APP_NAME"

# Check if the Container App exists
container_app_exists=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json 2>/dev/null)
if [[ -z "$container_app_exists" ]]; then
    echo "Error: Container App $CONTAINER_APP_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

issues_json='{"issues": []}'

# Get logs from the Container App
echo "Fetching recent logs for analysis (last ${TIME_PERIOD_MINUTES} minutes)..."

# Try to get logs using az containerapp logs
logs_output=$(az containerapp logs show \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --follow false \
    --tail 500 \
    --output json 2>/dev/null)

log_entries=""
if [[ $? -eq 0 && -n "$logs_output" ]]; then
    echo "Retrieved logs successfully from Container App."
    log_entries="$logs_output"
else
    echo "Failed to retrieve logs directly. Trying Log Analytics approach..."
    
    # Get the Container Apps Environment and try Log Analytics
    env_id=$(echo "$container_app_exists" | jq -r '.properties.environmentId // ""')
    if [[ -n "$env_id" && "$env_id" != "null" ]]; then
        env_name=$(echo "$env_id" | sed 's|.*/||')
        echo "Container Apps Environment: $env_name"
        
        # Try to get workspace info for the environment
        workspace_info=$(az containerapp env show \
            --name "$env_name" \
            --resource-group "$AZ_RESOURCE_GROUP" \
            --query "properties.appLogsConfiguration.logAnalyticsConfiguration.customerId" \
            --output tsv 2>/dev/null)
        
        if [[ -n "$workspace_info" && "$workspace_info" != "null" ]]; then
            echo "Querying Log Analytics workspace: $workspace_info"
            
            # KQL query to get container app logs with error analysis
            kql_query="ContainerAppConsoleLogs_CL 
            | where ContainerAppName_s == '$CONTAINER_APP_NAME' 
            | where TimeGenerated > ago(${TIME_PERIOD_MINUTES}m) 
            | project TimeGenerated, ContainerName_s, Log_s, Stream_s
            | order by TimeGenerated desc 
            | take 500"
            
            log_query_result=$(az monitor log-analytics query \
                --workspace "$workspace_info" \
                --analytics-query "$kql_query" \
                --output json 2>/dev/null)
            
            if [[ $? -eq 0 && -n "$log_query_result" ]]; then
                echo "Retrieved logs from Log Analytics."
                log_entries="$log_query_result"
            else
                echo "Log Analytics query failed or returned no results."
            fi
        fi
    fi
fi

# Analyze logs for errors and warnings
error_count=0
warning_count=0
critical_count=0
exception_count=0

error_patterns=("ERROR" "error" "Error" "FATAL" "fatal" "Fatal" "CRITICAL" "critical" "Critical")
warning_patterns=("WARN" "warn" "Warn" "WARNING" "warning" "Warning")
exception_patterns=("Exception" "exception" "EXCEPTION" "Traceback" "traceback" "StackTrace" "stacktrace")

echo "Analyzing log content for issues..."

if [[ -n "$log_entries" && "$log_entries" != "null" ]]; then
    # Create a temporary file to store log content for analysis
    temp_log_file=$(mktemp)
    
    # Extract log content based on the format
    if echo "$log_entries" | jq -e '.tables[0].rows' > /dev/null 2>&1; then
        # Log Analytics format
        echo "$log_entries" | jq -r '.tables[0].rows[] | .[3] // ""' > "$temp_log_file"
    elif echo "$log_entries" | jq -e '.[0].message' > /dev/null 2>&1; then
        # Container logs format
        echo "$log_entries" | jq -r '.[].message // ""' > "$temp_log_file"
    else
        # Plain text format
        echo "$log_entries" > "$temp_log_file"
    fi
    
    # Count errors
    for pattern in "${error_patterns[@]}"; do
        count=$(grep -i "$pattern" "$temp_log_file" | wc -l)
        error_count=$((error_count + count))
    done
    
    # Count warnings
    for pattern in "${warning_patterns[@]}"; do
        count=$(grep -i "$pattern" "$temp_log_file" | wc -l)
        warning_count=$((warning_count + count))
    done
    
    # Count exceptions
    for pattern in "${exception_patterns[@]}"; do
        count=$(grep -i "$pattern" "$temp_log_file" | wc -l)
        exception_count=$((exception_count + count))
    done
    
    # Count critical issues (subset of errors)
    critical_count=$(grep -iE "(critical|fatal)" "$temp_log_file" | wc -l)
    
    echo "Log analysis results:"
    echo "  Errors: $error_count"
    echo "  Warnings: $warning_count"
    echo "  Exceptions: $exception_count"
    echo "  Critical: $critical_count"
    
    # Generate issues based on log analysis
    if [[ $critical_count -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Critical Errors in Logs" \
            --arg nextStep "Immediately investigate $critical_count critical errors in Container App $CONTAINER_APP_NAME logs." \
            --arg severity "1" \
            --arg details "Found $critical_count critical/fatal errors in recent logs" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    if [[ $error_count -gt 10 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "High Error Rate in Logs" \
            --arg nextStep "Investigate $error_count errors in Container App $CONTAINER_APP_NAME logs to identify root causes." \
            --arg severity "2" \
            --arg details "Found $error_count errors in recent logs (threshold: 10)" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    elif [[ $error_count -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Errors Detected in Logs" \
            --arg nextStep "Review $error_count errors in Container App $CONTAINER_APP_NAME logs." \
            --arg severity "3" \
            --arg details "Found $error_count errors in recent logs" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    if [[ $exception_count -gt 5 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "High Exception Rate" \
            --arg nextStep "Investigate $exception_count exceptions in Container App $CONTAINER_APP_NAME to fix application issues." \
            --arg severity "2" \
            --arg details "Found $exception_count exceptions in recent logs (threshold: 5)" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    if [[ $warning_count -gt 20 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "High Warning Rate" \
            --arg nextStep "Review $warning_count warnings in Container App $CONTAINER_APP_NAME logs for potential issues." \
            --arg severity "4" \
            --arg details "Found $warning_count warnings in recent logs (threshold: 20)" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    # Look for specific patterns that indicate common issues
    oom_errors=$(grep -i "out of memory\|oom\|memory limit exceeded" "$temp_log_file" | wc -l)
    if [[ $oom_errors -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Out of Memory Errors" \
            --arg nextStep "Increase memory limits for Container App $CONTAINER_APP_NAME or optimize memory usage." \
            --arg severity "2" \
            --arg details "Found $oom_errors out-of-memory related errors in logs" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    connection_errors=$(grep -i "connection refused\|connection timeout\|connection failed\|network unreachable" "$temp_log_file" | wc -l)
    if [[ $connection_errors -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Network Connection Errors" \
            --arg nextStep "Investigate network connectivity issues for Container App $CONTAINER_APP_NAME." \
            --arg severity "3" \
            --arg details "Found $connection_errors network connection errors in logs" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    auth_errors=$(grep -i "unauthorized\|authentication failed\|access denied\|forbidden" "$temp_log_file" | wc -l)
    if [[ $auth_errors -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Authentication/Authorization Errors" \
            --arg nextStep "Review authentication configuration for Container App $CONTAINER_APP_NAME." \
            --arg severity "3" \
            --arg details "Found $auth_errors authentication/authorization errors in logs" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    # Clean up temporary file
    rm -f "$temp_log_file"
    
else
    echo "No log data available for analysis."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Log Data Available" \
        --arg nextStep "Check logging configuration for Container App $CONTAINER_APP_NAME. Ensure logs are being generated and collected." \
        --arg severity "3" \
        --arg details "No log data could be retrieved for analysis" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Get recent replica restart events as additional log analysis
echo "Checking for recent replica restarts..."
replicas_data=$(az containerapp replica list --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json 2>/dev/null)

if [[ -n "$replicas_data" && "$replicas_data" != "null" ]]; then
    restart_count=0
    while IFS= read -r replica; do
        restart_count_val=$(echo "$replica" | jq -r '.properties.restartCount // 0')
        restart_count=$((restart_count + restart_count_val))
    done < <(echo "$replicas_data" | jq -c '.[]')
    
    echo "Total restart count across replicas: $restart_count"
    
    if [[ $restart_count -gt $RESTART_COUNT_THRESHOLD ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "High Replica Restart Count" \
            --arg nextStep "Investigate frequent restarts for Container App $CONTAINER_APP_NAME. Check application stability and resource limits." \
            --arg severity "2" \
            --arg details "Total restart count: $restart_count (threshold: $RESTART_COUNT_THRESHOLD)" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
fi

# Generate log analysis summary
summary_file="container_app_log_analysis_summary.txt"
echo "Log Analysis Summary for Container App: $CONTAINER_APP_NAME" > "$summary_file"
echo "=======================================================" >> "$summary_file"
echo "Analysis Period: Last ${TIME_PERIOD_MINUTES} minutes" >> "$summary_file"
echo "Error Count: $error_count" >> "$summary_file"
echo "Warning Count: $warning_count" >> "$summary_file"
echo "Exception Count: $exception_count" >> "$summary_file"
echo "Critical Count: $critical_count" >> "$summary_file"
echo "Total Restarts: ${restart_count:-0}" >> "$summary_file"
echo "" >> "$summary_file"

if [[ $error_count -eq 0 && $warning_count -eq 0 && $exception_count -eq 0 ]]; then
    echo "No errors, warnings, or exceptions found in recent logs." >> "$summary_file"
else
    echo "Issues detected in log analysis. Review details below." >> "$summary_file"
fi

# Add issues to the summary
issue_count=$(echo "$issues_json" | jq '.issues | length')
echo "" >> "$summary_file"
echo "Issues Detected: $issue_count" >> "$summary_file"
echo "=======================================================" >> "$summary_file"
echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"

# Save JSON outputs
issues_file="container_app_log_issues.json"

echo "$issues_json" > "$issues_file"

# Final output
echo "Log analysis completed."
echo "Summary generated at: $summary_file"
echo "Issues JSON saved at: $issues_file" 