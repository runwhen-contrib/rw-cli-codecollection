#!/bin/bash

# ENV VARS:
#   FUNCTION_APP_NAME  - Name of the Azure Function App
#   AZ_RESOURCE_GROUP  - Resource group name
#   LOG_DIR            - (Optional) Directory to store logs (default: "function_app_logs")

LOG_DIR="${LOG_DIR:-"function_app_logs"}"

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

# Use functionapp instead of webapp
if az functionapp log download \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --log-file "$LOG_FILE" 2>/dev/null; then
    
    # Check if the zip was successfully downloaded
    if [[ -f "$LOG_FILE" ]]; then
        unzip -o "$LOG_FILE" -d "$LOG_DIR" 2>/dev/null
        rm "$LOG_FILE"
        chmod -R u+rw "$LOG_DIR" 2>/dev/null
    else
        echo "Warning: Failed to download logs."
        # Add a warning issue
        title="Unable to Download Logs for Function App $FUNCTION_APP_NAME"
        details="Unable to download logs for Function App $FUNCTION_APP_NAME. This may be due to the app being stopped or no logs being available."
        nextStep="Check if Function App $FUNCTION_APP_NAME is running and has logging enabled."
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
    fi
else
    echo "Warning: Failed to download logs."
    # Add a warning issue
    title="Unable to Download Logs for Function App $FUNCTION_APP_NAME"
    details="Unable to download logs for Function App $FUNCTION_APP_NAME. This may be due to the app being stopped or no logs being available."
    nextStep="Check if Function App $FUNCTION_APP_NAME is running and has logging enabled."
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
fi

# Step 2: Analyze logs if they exist
log_files=$(find "$LOG_DIR" -type f -name "*.log" 2>/dev/null)

if [[ -z "$log_files" ]]; then
    echo "No log files found."
    # Add an informational issue
    title="No Log Files Found for Function App $FUNCTION_APP_NAME"
    details="No log files found for Function App $FUNCTION_APP_NAME. This may be normal if the app is not actively running or logging is disabled."
    nextStep="Check if Function App $FUNCTION_APP_NAME is running and has logging enabled."
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
            errors=$(grep -iE 'error|failed|exception' "$log_file" 2>/dev/null | head -5)
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
        
        title="Log Errors Found in Function App $FUNCTION_APP_NAME"
        nextStep="Review log files to address $error_count errors found in Function App $FUNCTION_APP_NAME"
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
