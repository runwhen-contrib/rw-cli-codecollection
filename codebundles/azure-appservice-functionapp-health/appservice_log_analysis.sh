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

# Prepare the log file path
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/function_logs.zip"

echo "Downloading logs for Function App '$FUNCTION_APP_NAME' in resource group '$AZ_RESOURCE_GROUP'..."
az webapp log download \
  --name "$FUNCTION_APP_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --log-file "$LOG_FILE"

# Check if the zip was successfully downloaded
if [[ -f "$LOG_FILE" ]]; then
    echo "Extracting logs..."
    unzip -o "$LOG_FILE" -d "$LOG_DIR"
    rm "$LOG_FILE"

    echo "Fixing permissions for extracted files..."
    chmod -R u+rw "$LOG_DIR"
else
    echo "Error: Failed to download logs for Function App '$FUNCTION_APP_NAME'."
    exit 1
fi

# Step 2: Analyze logs
issues_json='{"issues": []}'
echo "Analyzing logs in '$LOG_DIR' for issues..."

log_files=$(find "$LOG_DIR" -type f -name "*.log")

if [[ -z "$log_files" ]]; then
    echo "No log files found in '$LOG_DIR'."
else
    for log_file in $log_files; do
        if [[ -f "$log_file" ]]; then
            echo "Processing log file: $log_file"
            ERROR_LOGS=$(grep -iE 'error|failed|exception' "$log_file")
            if [[ -n "$ERROR_LOGS" ]]; then
                echo "Errors found in $log_file:"
                echo "$ERROR_LOGS"
                issues_json=$(echo "$issues_json" | jq \
                    --arg funcName "$FUNCTION_APP_NAME" \
                    --arg logFile "$(basename "$log_file")" \
                    --arg details "$ERROR_LOGS" \
                    --arg nextStep "Review log file $(basename "$log_file") to address errors." \
                    --arg severity "3" \
                    '.issues += [{
                        "title": "Log File Errors with " + $funcName,
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
echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
echo "Log analysis completed. Results saved to $OUTPUT_FILE"
