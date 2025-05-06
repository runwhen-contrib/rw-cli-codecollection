#!/bin/bash

# Variables
LOG_DIR="${LOG_DIR:-"app_service_logs"}"

# Ensure required variables are set
if [[ -z "$APP_SERVICE_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "Error: APP_SERVICE_NAME and AZ_RESOURCE_GROUP environment variables must be set."
    exit 1
fi


# Step 1: Download logs
LOG_FILE="$LOG_DIR/app_logs.zip"
echo "Downloading logs for App Service '$APP_SERVICE_NAME' in resource group '$AZ_RESOURCE_GROUP'..."
az webapp log download --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --log-file "$LOG_FILE"

# Step 1: Extract logs and fix permissions
if [[ -f "$LOG_FILE" ]]; then
    echo "Extracting logs..."
    unzip -o "$LOG_FILE" -d "$LOG_DIR"
    rm "$LOG_FILE"

    # Fix permissions to ensure readability
    echo "Fixing permissions for extracted files..."
    chmod -R u+rw "$LOG_DIR"
else
    echo "Error: Failed to download logs."
    exit 1
fi


# Step 2: Analyze logs
issues_json='{"issues": []}'
echo "Analyzing logs in '$LOG_DIR' for issues..."

# Find all log files recursively
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
                    --arg logFile "$(basename "$log_file")" \
                    --arg details "$ERROR_LOGS" \
                    --arg nextStep "Review log file $(basename "$log_file") to address errors." \
                    --arg severity "3" \
                    '.issues += [{"title": "Log File Errors with '"$APP_SERVICE_NAME"'", "log_file": $logFile, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
            else
                echo "No significant errors found in $log_file."
            fi
        fi
    done
fi

# Step 3: Output issues report
echo "$issues_json" | jq '.' > "app_service_log_issues_report.json"
echo "Log analysis completed. Results saved to app_service_log_issues_report.json"
