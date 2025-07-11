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

echo "Downloading logs for Function App '$FUNCTION_APP_NAME' in resource group '$AZ_RESOURCE_GROUP'..."

# Use functionapp instead of webapp
if az functionapp log download \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --log-file "$LOG_FILE" 2>/dev/null; then
    
    # Check if the zip was successfully downloaded
    if [[ -f "$LOG_FILE" ]]; then
        echo "Extracting logs..."
        unzip -o "$LOG_FILE" -d "$LOG_DIR" 2>/dev/null
        rm "$LOG_FILE"

        echo "Fixing permissions for extracted files..."
        chmod -R u+rw "$LOG_DIR" 2>/dev/null
    else
        echo "Warning: Failed to download logs for Function App '$FUNCTION_APP_NAME'."
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
    echo "Warning: Failed to download logs for Function App '$FUNCTION_APP_NAME'."
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
echo "Analyzing logs in '$LOG_DIR' for issues..."

log_files=$(find "$LOG_DIR" -type f -name "*.log" 2>/dev/null)

if [[ -z "$log_files" ]]; then
    echo "No log files found in '$LOG_DIR'."
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
    for log_file in $log_files; do
        if [[ -f "$log_file" ]]; then
            echo "Processing log file: $log_file"
            ERROR_LOGS=$(grep -iE 'error|failed|exception' "$log_file" 2>/dev/null | head -10)
            if [[ -n "$ERROR_LOGS" ]]; then
                echo "Errors found in $log_file:"
                echo "$ERROR_LOGS"
                # Fix the jq syntax by using proper string concatenation
                title="Log File Errors with $FUNCTION_APP_NAME"
                nextStep="Review log file $(basename "$log_file") to address errors for Function App $FUNCTION_APP_NAME"
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "$title" \
                    --arg logFile "$(basename "$log_file")" \
                    --arg details "$ERROR_LOGS" \
                    --arg nextStep "$nextStep" \
                    --arg severity "3" \
                    '.issues += [{
                        "title": $title,
                        "log_file": $logFile,
                        "details": $details,
                        "next_step": $nextStep,
                        "severity": ($severity|tonumber)
                    }]'
                )
            else
                echo "No significant errors found in $log_file."
            fi
        fi
    done
fi

# Step 3: Output issues report
OUTPUT_FILE="function_app_log_issues_report.json"
echo "$issues_json" > "$OUTPUT_FILE"
echo "Log analysis completed. Results saved to $OUTPUT_FILE"

# Always ensure the file exists and is valid JSON
if [[ ! -f "$OUTPUT_FILE" ]]; then
    echo '{"issues": []}' > "$OUTPUT_FILE"
fi
