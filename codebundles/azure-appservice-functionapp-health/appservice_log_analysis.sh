#!/bin/bash

# ENV VARS:
#   FUNCTION_APP_NAME  - Name of the Azure Function App
#   AZ_RESOURCE_GROUP  - Resource group name
#   LOG_DIR            - (Optional) Directory to store logs (default: "function_app_logs")

LOG_DIR="${LOG_DIR:-"function_app_logs"}"

# Get subscription name from environment variable
subscription_name="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Ensure required variables are set
if [[ -z "$FUNCTION_APP_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "Error: FUNCTION_APP_NAME and AZ_RESOURCE_GROUP environment variables must be set."
    exit 1
fi

# Initialize the JSON object to store issues
issues_json='{"issues": []}'

# Prepare the log file path
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/function_logs.zip"

echo "Analyzing logs for Function App '$FUNCTION_APP_NAME'..."

# Track if we successfully downloaded logs in this session
logs_downloaded=false

# Use functionapp instead of webapp with timeout
echo "Attempting to download logs (timeout: 45 seconds)..."
if timeout 45s az functionapp log download \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --log-file "$LOG_FILE" 2>/dev/null; then
    
    # Check if the zip was successfully downloaded and has content
    if [[ -f "$LOG_FILE" && -s "$LOG_FILE" ]]; then
        echo "✅ Logs downloaded successfully"
        logs_downloaded=true
        
        # Extract logs
        if timeout 15s unzip -o "$LOG_FILE" -d "$LOG_DIR" 2>/dev/null; then
            rm "$LOG_FILE"
            chmod -R u+rw "$LOG_DIR" 2>/dev/null
        else
            echo "Warning: Failed to extract downloaded logs"
        fi
    else
        echo "Warning: Log download completed but file is empty or missing"
        logs_downloaded=false
    fi
else
    echo "Warning: Failed to download logs within timeout period."
    logs_downloaded=false
fi

# If we couldn't download logs, create an issue and exit early
if [[ "$logs_downloaded" == "false" ]]; then
    echo "No fresh logs available for analysis"
    title="Unable to Download Logs for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`"
    details="Unable to download logs for Function App $FUNCTION_APP_NAME in subscription $subscription_name. This may be due to the app being stopped, no logs being available, or network connectivity issues."
    nextStep="Check if Function App $FUNCTION_APP_NAME is running and has logging enabled in subscription $subscription_name"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg details "$details" \
        --arg nextStep "$nextStep" \
        --arg severity "4" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity|tonumber)
        }]'
    )
    
    # Output issues report and exit
    OUTPUT_FILE="function_app_log_issues_report.json"
    echo "$issues_json" > "$OUTPUT_FILE"
    echo "Log analysis completed."
    exit 0
fi

# Step 2: Analyze logs if they were successfully downloaded
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
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity|tonumber)
        }]'
    )
else
    echo "Found $(echo "$log_files" | wc -l) log files. Analyzing for errors..."
    
    # Collect all errors from all log files
    all_errors=""
    error_count=0
    
    for log_file in $log_files; do
        if [[ -f "$log_file" ]]; then
            # Get up to 5 errors per log file to avoid overwhelming output
            errors=$(timeout 10s grep -iE 'error|failed|exception' "$log_file" 2>/dev/null | head -5)
            if [[ -n "$errors" ]]; then
                all_errors="${all_errors}${all_errors:+$'\n\n'}=== $(basename "$log_file") ===${all_errors:+$'\n'}$errors"
                error_count=$((error_count + $(echo "$errors" | wc -l)))
            fi
        fi
    done
    
    if [[ -n "$all_errors" ]]; then
        echo "Found $error_count errors across log files."
        # Limit the error details to avoid overwhelming the report
        if [[ $error_count -gt 10 ]]; then
            all_errors=$(echo "$all_errors" | head -50)
            all_errors="${all_errors}${all_errors:+$'\n\n'}... (showing first 50 lines, $error_count total errors found)"
        fi
        
        title="Log Errors Found in Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`"
        nextStep="Review log files to address $error_count errors found in Function App $FUNCTION_APP_NAME in subscription $subscription_name"
        issues_json=$(echo "$issues_json" | jq \
            --arg title "$title" \
            --arg details "$all_errors" \
            --arg nextStep "$nextStep" \
            --arg severity "3" \
            '.issues += [{
                "title": $title,
                "details": $details,
                "next_step": $nextStep,
                "severity": ($severity|tonumber)
            }]'
        )
    else
        echo "No significant errors found in log files."
    fi
fi

# Step 3: Output issues report
OUTPUT_FILE="function_app_log_issues_report.json"
echo "$issues_json" > "$OUTPUT_FILE"

# Always ensure the file exists and is valid JSON
if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo '{"issues": []}' > "$OUTPUT_FILE"
fi

echo "Log analysis completed."
