#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP
# LOG_LEVEL (Optional, default is INFO)
# MAX_LOG_LINES (Optional, default is 100)

# Set defaults
LOG_LEVEL="${LOG_LEVEL:-INFO}"
MAX_LOG_LINES="${MAX_LOG_LINES:-100}"
MAX_TOTAL_SIZE="${MAX_TOTAL_SIZE:-500000}"  # 500KB limit

LOG_PATH="_rw_logs_$APP_SERVICE_NAME.zip"
subscription_id=$(az account show --query "id" -o tsv)

# Set the subscription
az account set --subscription $subscription_id

# Download and extract logs
az webapp log download --name $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --subscription $subscription_id --log-file $LOG_PATH

TEMP_DIR="/tmp/_temp_logs_$$"
mkdir -p "$TEMP_DIR"
unzip -o $LOG_PATH -d "$TEMP_DIR" >/dev/null 2>&1
# Fix permissions on extracted files
chmod -R 755 "$TEMP_DIR" 2>/dev/null || true

output_size=0
max_exceeded=false

echo "Azure App Service $APP_SERVICE_NAME logs (Level: $LOG_LEVEL, Max Lines: $MAX_LOG_LINES):"
echo ""

# Function to add content with size check
add_content() {
    local content="$1"
    local content_size=${#content}
    
    if (( output_size + content_size > MAX_TOTAL_SIZE )); then
        if [ "$max_exceeded" = false ]; then
            echo ""
            echo "⚠️  Output truncated - size limit reached (${MAX_TOTAL_SIZE} bytes)"
            echo "💡 To see more logs, reduce LOG_LEVEL to ERROR or WARN, or download logs directly from Azure Portal"
            max_exceeded=true
        fi
        return 1
    fi
    
    echo "$content"
    output_size=$((output_size + content_size))
    return 0
}

# Define log level priorities for filtering (compatible with older bash)
case "$LOG_LEVEL" in
    "ERROR") CURRENT_PRIORITY=1 ;;
    "WARN") CURRENT_PRIORITY=2 ;;
    "INFO") CURRENT_PRIORITY=3 ;;
    "DEBUG") CURRENT_PRIORITY=4 ;;
    "VERBOSE") CURRENT_PRIORITY=5 ;;
    *) CURRENT_PRIORITY=3 ;;  # Default to INFO
esac

# Display Application logs (errors, warnings, app output)
if [ -d "$TEMP_DIR/LogFiles/Application" ]; then
    add_content "=== Application Logs ===" || exit 0
    
    for log_file in "$TEMP_DIR/LogFiles/Application"/*; do
        if [ -f "$log_file" ]; then
            add_content "--- $(basename "$log_file") ---" || exit 0
            
            # Filter by log level - only show errors/warnings for INFO and above
            if [ "$CURRENT_PRIORITY" -le 3 ]; then
                # For INFO level and higher, filter for important entries
                filtered_content=$(grep -iE 'error|warn|exception|fail|critical' "$log_file" | tail -n "$MAX_LOG_LINES" 2>/dev/null || echo "No errors/warnings found in recent logs")
            else
                # For DEBUG/VERBOSE, show more content but still limited
                filtered_content=$(tail -n "$MAX_LOG_LINES" "$log_file")
            fi
            
            add_content "$filtered_content" || exit 0
            add_content "" || exit 0
        fi
    done
else
    add_content "No Application logs directory found" || exit 0
fi

# Display Detailed Error logs (4xx/5xx errors) - always include if present
if [ -d "$TEMP_DIR/LogFiles/DetailedErrors" ]; then
    add_content "=== Detailed Error Logs ===" || exit 0
    
    for error_file in "$TEMP_DIR/LogFiles/DetailedErrors"/*; do
        if [ -f "$error_file" ]; then
            add_content "--- $(basename "$error_file") ---" || exit 0
            error_content=$(cat "$error_file")
            add_content "$error_content" || exit 0
            add_content "" || exit 0
        fi
    done
fi

# Display System Event Log (summary only) - avoid verbose XML dumps
if [ -f "$TEMP_DIR/LogFiles/eventlog.xml" ] && [ "$CURRENT_PRIORITY" -ge 4 ]; then
    add_content "=== System Events (Last 20 Events) ===" || exit 0
    if command -v xmllint &>/dev/null; then
        event_summary=$(xmllint --xpath '//Event[position()<=20]/concat("Time=", System/TimeCreated/@SystemTime, " | Level=", System/Level/text(), " | Message=", substring(RenderingInfo/Message/text(), 1, 100), "\n")' "$TEMP_DIR/LogFiles/eventlog.xml" 2>/dev/null || echo "No recent system events")
        add_content "$event_summary" || exit 0
    else
        add_content "xmllint not available, skipping system events" || exit 0
    fi
fi

# # Cleanup
# rm -rf "$TEMP_DIR" "$LOG_PATH"

echo ""
echo "📊 Output size: ${output_size} bytes (Limit: ${MAX_TOTAL_SIZE} bytes)"
if [ "$max_exceeded" = true ]; then
    echo "🔍 For complete logs, visit: https://portal.azure.com and navigate to your App Service > Logs"
fi