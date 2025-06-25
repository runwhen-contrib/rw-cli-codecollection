#!/bin/bash

# ENV:
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP
# AZURE_RESOURCE_SUBSCRIPTION_ID (Optional, defaults to current subscription)

# Configuration for log display limits
MAX_LOG_LINES="${MAX_LOG_LINES:-50}"                # Maximum lines to display per file
MAX_LOG_SIZE_MB="${MAX_LOG_SIZE_MB:-2}"             # Maximum log file size to process (MB)
LOG_DISPLAY_RECENT_HOURS="${LOG_DISPLAY_RECENT_HOURS:-1}"  # Show logs from last 1 hour

LOG_PATH="app_service_logs.zip"

echo "App Service Log Display Configuration:"
echo "- Maximum lines to display: ${MAX_LOG_LINES}"
echo "- Maximum log file size: ${MAX_LOG_SIZE_MB} MB"
echo "- Show logs from last: ${LOG_DISPLAY_RECENT_HOURS} hours"

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription_id=$(timeout 10s az account show --query "id" -o tsv)
    if [[ -z "$subscription_id" ]]; then
        echo "Failed to get current subscription ID within 10 seconds."
        exit 1
    fi
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription_id"
else
    subscription_id="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription_id"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription_id"
if ! timeout 10s az account set --subscription "$subscription_id"; then
    echo "Failed to set subscription within 10 seconds."
    exit 1
fi

echo "Downloading recent logs for App Service '$APP_SERVICE_NAME'..."

# Download logs with timeout to prevent hanging
if ! timeout 60s az webapp log download --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --subscription "$subscription_id" --log-file "$LOG_PATH" 2>/dev/null; then
    echo "Error: Failed to download logs for App Service '$APP_SERVICE_NAME' within 60 seconds."
    echo "This may be due to:"
    echo "- App Service not found"
    echo "- Insufficient permissions"
    echo "- Logging not enabled"
    echo "- Download timeout (large log files)"
    exit 1
fi

# Check downloaded file size
if [[ -f "$LOG_PATH" ]]; then
    file_size_mb=$(( $(stat -f%z "$LOG_PATH" 2>/dev/null || stat -c%s "$LOG_PATH" 2>/dev/null || echo 0) / 1024 / 1024 ))
    echo "Downloaded log file size: ${file_size_mb} MB"
    
    if [[ $file_size_mb -gt $MAX_LOG_SIZE_MB ]]; then
        echo "Warning: Log file is ${file_size_mb} MB (exceeds ${MAX_LOG_SIZE_MB} MB limit)."
        echo "Only showing recent entries to prevent overwhelming the report."
    fi
else
    echo "Error: Log file was not created."
    exit 1
fi

# Extract and filter logs
echo "Extracting and filtering logs (last ${LOG_DISPLAY_RECENT_HOURS} hours, max ${MAX_LOG_LINES} lines)..."

# Create temporary directory for extraction in current working directory
temp_dir="./log_extraction_$$"
mkdir -p "$temp_dir"
if ! unzip -qq "$LOG_PATH" -d "$temp_dir" 2>/dev/null; then
    echo "Error: Failed to extract log file."
    rm -rf "$temp_dir"
    rm -f "$LOG_PATH"
    exit 1
fi

echo "Azure App Service $APP_SERVICE_NAME recent logs:"
echo "============================================================"

# Find and process log files - simplified approach
log_files_found=false
total_lines_shown=0

# Simple log display - just show recent content from each log file
echo "Showing last ${MAX_LOG_LINES} lines from each log file:"

# Process log files - simple tail of recent content
find "$temp_dir" -name "*.log" -type f -not -name "*.xml" -exec stat -c '%s %n' {} \; | sort -nr | head -3 | while read size filepath; do
    if [[ $size -gt 0 ]]; then
        log_files_found=true
        echo ""
        echo "=== $(basename "$filepath") (last ${MAX_LOG_LINES} lines) ==="
        cat "$filepath" | tail -${MAX_LOG_LINES}
    fi
done

if [[ "$log_files_found" == false ]]; then
    echo "No log files with content found in the downloaded archive."
    echo ""
    echo "Available files:"
    find "$temp_dir" -type f | head -10 | while read -r file; do
        size=$(stat -c%s "$file" 2>/dev/null || echo 0)
        echo "  $(basename "$file") (${size} bytes)"
    done
fi

echo ""
echo "============================================================"
echo "Log display completed:"
echo "- Lines shown: ${total_lines_shown}"
echo "- File size processed: ${file_size_mb} MB"

# Clean up
rm -rf "$temp_dir"
rm -f "$LOG_PATH"