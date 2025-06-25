#!/bin/bash

# Variables
LOG_DIR="${LOG_DIR:-"app_service_logs"}"
OUTPUT_FILE="app_service_log_issues_report.json"

# Initialize issues JSON - this ensures we always have valid output
issues_json='{"issues": []}'

# Ensure required variables are set
if [[ -z "$APP_SERVICE_NAME" || -z "$AZ_RESOURCE_GROUP" ]]; then
    echo "Error: APP_SERVICE_NAME and AZ_RESOURCE_GROUP environment variables must be set."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Required Environment Variables" \
        --arg details "APP_SERVICE_NAME and AZ_RESOURCE_GROUP must be set for log analysis" \
        --arg nextStep "Set required environment variables and retry log analysis" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
    echo "Error: Missing required environment variables. Results saved to $OUTPUT_FILE"
    exit 1
fi

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Step 1: Download logs
LOG_FILE="$LOG_DIR/app_logs.zip"
echo "Downloading logs for App Service '$APP_SERVICE_NAME' in resource group '$AZ_RESOURCE_GROUP'..."

if ! az webapp log download --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --log-file "$LOG_FILE" 2>/dev/null; then
    echo "Error: Failed to download logs."
    # Add issue but continue - this is not necessarily a critical failure
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to Download App Service Logs for \`$APP_SERVICE_NAME\`" \
        --arg details "Could not download logs from App Service. This may be due to insufficient permissions, disabled logging, or the app service not existing" \
        --arg nextStep "Check App Service logging configuration and permissions for \`$APP_SERVICE_NAME\` in RG \`$AZ_RESOURCE_GROUP\`" \
        --arg severity "4" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    
    # Save results and exit - no logs to analyze
    echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
    echo "Log download failed. Results saved to $OUTPUT_FILE"
    exit 0
fi

# Step 2: Extract logs and fix permissions
if [[ -f "$LOG_FILE" ]]; then
    echo "Extracting logs..."
    if ! unzip -o "$LOG_FILE" -d "$LOG_DIR" 2>/dev/null; then
        echo "Error: Failed to extract logs."
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to Extract App Service Logs for \`$APP_SERVICE_NAME\`" \
            --arg details "Downloaded log file could not be extracted. File may be corrupted" \
            --arg nextStep "Retry log download for \`$APP_SERVICE_NAME\` or check log file integrity" \
            --arg severity "3" \
            '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
        echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
        echo "Log extraction failed. Results saved to $OUTPUT_FILE"
        exit 0
    fi
    
    # Clean up zip file
    rm -f "$LOG_FILE"
    
    # Fix permissions to ensure readability
    echo "Fixing permissions for extracted files..."
    chmod -R u+rw "$LOG_DIR" 2>/dev/null || true
else
    echo "Error: Log file was not created."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Log File Not Created for \`$APP_SERVICE_NAME\`" \
        --arg details "Log download appeared to succeed but no file was created" \
        --arg nextStep "Check App Service logging configuration and retry for \`$APP_SERVICE_NAME\`" \
        --arg severity "3" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
    echo "Log file not found. Results saved to $OUTPUT_FILE"
    exit 0
fi

# Step 3: Analyze logs
echo "Analyzing logs in '$LOG_DIR' for issues..."

# Find all log files recursively
log_files=$(find "$LOG_DIR" -type f \( -name "*.log" -o -name "*.txt" \) 2>/dev/null)

if [[ -z "$log_files" ]]; then
    echo "No log files found in '$LOG_DIR'."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Log Files Found for \`$APP_SERVICE_NAME\`" \
        --arg details "Log extraction completed but no .log or .txt files were found to analyze" \
        --arg nextStep "Check App Service logging configuration to ensure logs are being generated for \`$APP_SERVICE_NAME\`" \
        --arg severity "4" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
else
    # Process each log file
    for log_file in $log_files; do
        if [[ -f "$log_file" && -r "$log_file" ]]; then
            echo "Processing log file: $log_file"
            
            # Look for error patterns (case insensitive)
            if ERROR_LOGS=$(grep -iE 'error|failed|exception|fatal|critical' "$log_file" 2>/dev/null | head -20); then
                if [[ -n "$ERROR_LOGS" ]]; then
                    echo "Errors found in $log_file:"
                    echo "$ERROR_LOGS"
                    
                    # Count the errors to determine severity
                    error_count=$(echo "$ERROR_LOGS" | wc -l)
                    if [[ $error_count -gt 10 ]]; then
                        severity="2"  # High error volume
                    else
                        severity="3"  # Normal error level
                    fi
                    
                    issues_json=$(echo "$issues_json" | jq \
                        --arg title "Log Errors Detected in \`$APP_SERVICE_NAME\`" \
                        --arg logFile "$(basename "$log_file")" \
                        --arg details "Found $error_count error entries in $(basename "$log_file"): $ERROR_LOGS" \
                        --arg nextStep "Review log file $(basename "$log_file") to address application errors for \`$APP_SERVICE_NAME\`" \
                        --arg severity "$severity" \
                        '.issues += [{"title": $title, "log_file": $logFile, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
                fi
            else
                echo "No significant errors found in $log_file."
            fi
        else
            echo "Warning: Could not read log file $log_file"
        fi
    done
fi

# Step 4: Always output issues report
echo "$issues_json" | jq '.' > "$OUTPUT_FILE"
echo "Log analysis completed. Results saved to $OUTPUT_FILE"

# Cleanup log directory to save space (optional)
# rm -rf "$LOG_DIR"
