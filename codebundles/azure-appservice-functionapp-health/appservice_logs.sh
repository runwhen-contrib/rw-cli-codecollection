#!/bin/bash

# ENV:
#   FUNCTION_APP_NAME  - Name of the Azure Function App
#   AZ_RESOURCE_GROUP  - Resource group containing the Function App
#   AZURE_RESOURCE_SUBSCRIPTION_ID - (Optional) Subscription ID (defaults to current subscription)

# Use subscription ID from environment variable
subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Using subscription ID: $subscription_id"

# Get subscription name from environment variable
subscription_name="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Set the subscription to the determined ID with timeout
if ! timeout 10s az account set --subscription "$subscription_id" 2>/dev/null; then
    echo "Failed to set subscription within timeout."
    exit 1
fi

# Name of the zip file to store logs
LOG_PATH="_rw_logs_${FUNCTION_APP_NAME}.zip"
LOG_DIR="function_app_logs"

# Initialize the JSON object to store issues
issues_json='{"issues": []}'

echo "Downloading and analyzing logs for Azure Function App: $FUNCTION_APP_NAME..."

# Check if function app exists and is running first
echo "Checking Function App status..."
if ! function_app_status=$(timeout 15s az functionapp show --name "$FUNCTION_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv 2>/dev/null); then
    echo "Error: Could not retrieve Function App status. Function App may not exist or access may be restricted."
    exit 1
fi

if [[ "$function_app_status" != "Running" ]]; then
    echo "Warning: Function App is not running (status: $function_app_status). Log download may fail."
fi

# Track if we successfully downloaded logs in this session
logs_downloaded=false

# Download logs with timeout
echo "Attempting to download logs (timeout: 90 seconds)..."
if timeout 90s az webapp log download \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --subscription "$subscription_id" \
  --log-file "$LOG_PATH" 2>/dev/null; then
    
    # Check if the log file was actually created and has content
    if [[ -f "$LOG_PATH" && -s "$LOG_PATH" ]]; then
        echo "✅ Log files downloaded successfully"
        logs_downloaded=true
        
        # Unzip and display a summary of the contents with timeout
        echo "Log files found:"
        if timeout 10s unzip -l "$LOG_PATH" 2>/dev/null | head -10; then
            echo ""
            echo "Recent log entries (last 20 lines):"
            if timeout 15s unzip -qq -c "$LOG_PATH" 2>/dev/null | grep -E "(ERROR|WARN|Exception|Failed)" | tail -20; then
                echo ""
            else
                echo "No recent errors found in logs."
            fi
        else
            echo "Warning: Could not read log file contents within timeout"
        fi
        
        # Extract logs for analysis
        if timeout 15s unzip -o "$LOG_PATH" -d "$LOG_DIR" 2>/dev/null; then
            chmod -R u+rw "$LOG_DIR" 2>/dev/null
        else
            echo "Warning: Failed to extract downloaded logs for analysis"
        fi
        
        # Clean up zip file
        rm -f "$LOG_PATH"
    else
        echo "Warning: Log file was not created or is empty"
        logs_downloaded=false
    fi
else
    echo "Warning: Unable to download logs within timeout period."
    echo "This could be due to:"
    echo "  - Function App is stopped"
    echo "  - Logging is disabled"
    echo "  - Network connectivity issues"
    echo "  - Insufficient permissions"
    logs_downloaded=false
    
    # Try to get log stream as fallback
    echo ""
    echo "Attempting to get recent log stream (timeout: 30 seconds)..."
    if timeout 30s az webapp log tail \
      --name "$FUNCTION_APP_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --subscription "$subscription_id" \
      --provider docker 2>/dev/null | head -50; then
        echo ""
        echo "✅ Retrieved recent log stream"
    else
        echo "Warning: Could not retrieve log stream either"
    fi
fi

# Step 2: Analyze logs if they were successfully downloaded
if [[ "$logs_downloaded" == "true" ]]; then
    echo ""
    echo "📊 Analyzing logs for errors and issues..."
    
    log_files=$(find "$LOG_DIR" -type f -name "*.log" 2>/dev/null)
    
    if [[ -z "$log_files" ]]; then
        echo "No log files found in downloaded logs."
        # Add an informational issue
        title="No Log Files Found for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`"
        details="No log files found for Function App $FUNCTION_APP_NAME in subscription $subscription_name. This may be normal if the app is not actively running or logging is disabled."
        nextStep="Check if Function App $FUNCTION_APP_NAME is running and has logging enabled in subscription $subscription_name"
        issues_json=$(echo "$issues_json" | jq \
            --arg title "$title" \
            --arg details "$details" \
            --arg nextStep "$nextStep" \
            --arg severity "4" \
            --arg summary "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` has no log files available, indicating that either the app is not actively running or logging is disabled. Immediate actions are needed to verify the app's runtime status, validate logging configuration, and ensure that logs are properly generated and persisted." \
            '.issues += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity|tonumber),
                "summary": $summary
            }]'
        )
    else
        # Analyze log files for errors
        error_count=0
        warning_count=0
        critical_count=0
        error_details=""
        
        for log_file in $log_files; do
            echo "Analyzing: $(basename "$log_file")"
            
            # Count different types of log entries
            errors=$(grep -i "error\|exception\|failed" "$log_file" 2>/dev/null | wc -l)
            warnings=$(grep -i "warn" "$log_file" 2>/dev/null | wc -l)
            critical=$(grep -i "critical\|fatal" "$log_file" 2>/dev/null | wc -l)
            
            error_count=$((error_count + errors))
            warning_count=$((warning_count + warnings))
            critical_count=$((critical_count + critical))
            
            # Get recent error details
            recent_errors=$(grep -i "error\|exception\|failed" "$log_file" 2>/dev/null | tail -5 | sed 's/"/\\"/g')
            if [[ -n "$recent_errors" ]]; then
                error_details="$error_details\n$(basename "$log_file"):\n$recent_errors"
            fi
        done
        
        total_issues=$((error_count + warning_count + critical_count))
        
        if [[ $total_issues -gt 0 ]]; then
            echo "⚠️  Found log issues: $error_count errors, $warning_count warnings, $critical_count critical"
            
            # Determine severity based on issue count
            severity=4  # Info by default
            if [[ $critical_count -gt 0 ]]; then
                severity=1  # Critical
            elif [[ $error_count -gt 5 ]]; then
                severity=2  # Error
            elif [[ $warning_count -gt 10 ]]; then
                severity=3  # Warning
            fi

            # Extract the last timestamp from error details
            observed_at=$(echo -e "$error_details" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z?' | tail -1)
            if [[ -z "$observed_at" ]]; then
                # Fallback to current time if no timestamp found in logs
                observed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            fi
            
            title="Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` has log issues detected"
            details="Log analysis for Function App $FUNCTION_APP_NAME in subscription $subscription_name found:\n- Errors: $error_count\n- Warnings: $warning_count\n- Critical: $critical_count\n\nRecent error details:$error_details\n\nPossible Causes:\n- Application code errors\n- Configuration issues\n- Dependency failures\n- Resource constraints"
            nextStep="Review Application Insights logs for detailed error traces and check function configuration"
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "$title" \
                --arg details "$details" \
                --arg nextStep "$nextStep" \
                --arg severity "$severity" \
                --arg observed_at "$observed_at" \
                --arg summary "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` generated $error_count errors and $warning_count warnings in logs contrary to the expected state where no warnings, errors, or critical logs were detected. Actions needed include reviewing Application Insights logs, investigating dependency failures, analyzing resource utilization, validating workload configuration, and assessing resource constraints." \
                '.issues += [{
                    "title": $title,
                    "details": $details,
                    "next_step": $nextStep,
                    "severity": ($severity|tonumber),
                    "observed_at": $observed_at,
                    "summary": $summary
                }]'
            )
        else
            echo "✅ No log issues detected"
            # Add a positive issue
            title="Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` has no log issues"
            details="Log analysis for Function App $FUNCTION_APP_NAME in subscription $subscription_name found no errors, warnings, or critical issues in the analyzed logs."
            nextStep="Continue monitoring function performance and maintain current operational practices"
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "$title" \
                --arg details "$details" \
                --arg nextStep "$nextStep" \
                --arg severity "4" \
                --arg summary "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` was analyzed, and no errors, warnings, or critical log issues were found, which meets the expected state for resource group \`$AZ_RESOURCE_GROUP\`. No immediate issues require remediation." \
                '.issues += [{
                    "title": $title,
                    "details": $details,
                    "next_step": $nextStep,
                    "severity": ($severity|tonumber),
                    "summary": $summary
                }]'
            )
        fi
    fi
else
    # If we couldn't download logs, create an issue
    echo "No fresh logs available for analysis"
    title="Unable to Download Logs for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`"
    details="Unable to download logs for Function App $FUNCTION_APP_NAME in subscription $subscription_name. This may be due to the app being stopped, no logs being available, or network connectivity issues."
    nextStep="Check if Function App $FUNCTION_APP_NAME is running and has logging enabled in subscription $subscription_name"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg details "$details" \
        --arg nextStep "$nextStep" \
        --arg severity "4" \
        --arg summary "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` failed to provide downloadable logs, possibly due to the app being stopped or logs not being generated. It was expected to have no Warning, Error, or Critical logs, but issues were detected that require further investigation." \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity|tonumber),
            "summary": $summary
        }]'
    )
fi

# Output issues report
OUTPUT_FILE="function_app_log_issues_report.json"
echo "$issues_json" > "$OUTPUT_FILE"

# Clean up extracted logs
rm -rf "$LOG_DIR" 2>/dev/null

echo ""
echo "Log retrieval and analysis completed."
