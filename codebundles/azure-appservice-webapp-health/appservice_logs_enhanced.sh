#!/bin/bash

# Enhanced Azure App Service Logs Collection Script
# Implements all optimization phases while maintaining size limits
# 
# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP
# LOG_LEVEL (Optional, default is INFO)
# MAX_LOG_LINES (Optional, default is 100)
# INCLUDE_DOCKER_LOGS (Optional, default is true)
# INCLUDE_DEPLOYMENT_LOGS (Optional, default is true)
# INCLUDE_PERFORMANCE_TRACES (Optional, default is false)

# Set defaults
LOG_LEVEL="${LOG_LEVEL:-INFO}"
MAX_LOG_LINES="${MAX_LOG_LINES:-100}"
MAX_TOTAL_SIZE="${MAX_TOTAL_SIZE:-500000}"  # 500KB limit
INCLUDE_DOCKER_LOGS="${INCLUDE_DOCKER_LOGS:-true}"
INCLUDE_DEPLOYMENT_LOGS="${INCLUDE_DEPLOYMENT_LOGS:-true}"
INCLUDE_PERFORMANCE_TRACES="${INCLUDE_PERFORMANCE_TRACES:-false}"

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

echo "Azure App Service $APP_SERVICE_NAME Enhanced Logs (Level: $LOG_LEVEL, Max Lines: $MAX_LOG_LINES):"
echo "Features: Docker[${INCLUDE_DOCKER_LOGS}] | Deployments[${INCLUDE_DEPLOYMENT_LOGS}] | Performance[${INCLUDE_PERFORMANCE_TRACES}]"
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

# =============================================================================
# PHASE 1: APPLICATION LOGS (CORE - ALWAYS INCLUDED)
# =============================================================================
# Debug: Check what's in the temp directory
if [ "$CURRENT_PRIORITY" -ge 4 ]; then
    add_content "=== Debug: Temp Directory Contents ===" || exit 0
    add_content "Temp dir: $TEMP_DIR" || exit 0
    add_content "Contents: $(ls -la "$TEMP_DIR" 2>/dev/null || echo 'No temp dir found')" || exit 0
    if [ -d "$TEMP_DIR/LogFiles" ]; then
        add_content "LogFiles contents: $(ls -la "$TEMP_DIR/LogFiles" 2>/dev/null || echo 'No LogFiles dir')" || exit 0
    fi
    add_content "" || exit 0
fi

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

# =============================================================================
# DOCKER CONTAINER LOGS
# =============================================================================
if [ "$INCLUDE_DOCKER_LOGS" = "true" ] && [ -d "$TEMP_DIR/LogFiles" ]; then
    docker_logs_found=false
    
    for docker_log in "$TEMP_DIR/LogFiles"/*_default_docker.log "$TEMP_DIR/LogFiles"/*_docker.log; do
        if [ -f "$docker_log" ]; then
            if [ "$docker_logs_found" = false ]; then
                add_content "=== Docker Container Logs ===" || exit 0
                docker_logs_found=true
            fi
            
            add_content "--- $(basename "$docker_log") ---" || exit 0
            
            # Smart filtering based on log level - FOCUS ON ACTUAL PROBLEMS
            if [ "$CURRENT_PRIORITY" -le 2 ]; then
                # ERROR/WARN: Only critical failures (deduplicated)
                filtered_content=$(grep -iE 'not found|error|fail|fatal|exception|exit.*[1-9]|denied|unable|cannot' "$docker_log" | sort -u | head -8 2>/dev/null || echo "No critical issues found")
            elif [ "$CURRENT_PRIORITY" -eq 3 ]; then
                # INFO: Show unique errors + key startup info
                temp_content=$(
                    # Show unique critical errors
                    grep -iE 'not found|error|fail|fatal|exception|exit.*[1-9]|denied|unable|cannot' "$docker_log" | sort -u | head -5
                    # Show application startup attempts (unique)
                    grep -iE 'npm start|next start|blog.*start' "$docker_log" | sort -u | head -3
                    # Show ONE port configuration line, not all 40
                    grep -E 'export PORT=' "$docker_log" | head -1
                )
                # Add restart/failure summary separately
                restart_count=$(grep -c 'export PORT=' "$docker_log" 2>/dev/null || echo "0")
                error_count=$(grep -c 'not found|error|fail|fatal|exception|exit.*[1-9]|denied|unable|cannot' "$docker_log" 2>/dev/null || echo "0")
                # Ensure we have valid integers
                restart_count=${restart_count//[^0-9]/}
                error_count=${error_count//[^0-9]/}
                restart_count=${restart_count:-0}
                error_count=${error_count:-0}
                if [ "$restart_count" -gt 1 ]; then
                    temp_content="$temp_content"$'\n'"INFO: Container restarted $restart_count times with $error_count error logs"
                fi
                filtered_content=$(echo "$temp_content" | grep -v '^$' | head -10 2>/dev/null || echo "No significant events found")
            else
                # DEBUG/VERBOSE: More detailed but still avoid excessive repetition
                temp_content=$(
                    # Unique errors and failures
                    grep -iE 'not found|error|fail|fatal|exception|exit.*[1-9]|denied|unable|cannot' "$docker_log" | sort -u | head -8
                    # Key startup events (unique)
                    grep -iE 'app.*service.*on.*linux|npm.*start|build.*operation|manifest' "$docker_log" | sort -u | head -5
                    # Port and environment info (limited)
                    grep -E 'export PORT=|NODE_PATH=' "$docker_log" | head -2
                )
                # Container restart summary separately
                restart_count=$(grep -c 'A P P   S E R V I C E   O N   L I N U X' "$docker_log" 2>/dev/null || echo "0")
                # Ensure we have a valid integer
                restart_count=${restart_count//[^0-9]/}
                restart_count=${restart_count:-0}
                if [ "$restart_count" -gt 1 ]; then
                    temp_content="$temp_content"$'\n'"DEBUG: Container restarted $restart_count times during log period"
                fi
                filtered_content=$(echo "$temp_content" | grep -v '^$' | head -15 2>/dev/null || tail -n 15 "$docker_log")
            fi
            
            add_content "$filtered_content" || exit 0
            add_content "" || exit 0
        fi
    done
    
    if [ "$docker_logs_found" = false ] && [ "$CURRENT_PRIORITY" -ge 4 ]; then
        add_content "=== Docker Container Logs ===" || exit 0
        add_content "No Docker container logs found" || exit 0
        add_content "" || exit 0
    fi
fi

# =============================================================================
# RECENT DEPLOYMENT HISTORY
# =============================================================================
if [ "$INCLUDE_DEPLOYMENT_LOGS" = "true" ] && [ -d "$TEMP_DIR/deployments" ] && [ "$CURRENT_PRIORITY" -ge 3 ]; then
    add_content "=== Recent Deployments (Last 3) ===" || exit 0
    
    deployment_count=0
    # Sort by modification time, newest first
    for deployment_dir in $(find "$TEMP_DIR/deployments" -name "log.log" -exec ls -t {} \; 2>/dev/null | head -3); do
        if [ -f "$deployment_dir" ]; then
            deployment_id=$(basename "$(dirname "$deployment_dir")")
            add_content "--- Deployment: ${deployment_id:0:8}... ---" || exit 0
            
            # Show key deployment events and outcomes
            if [ "$CURRENT_PRIORITY" -le 3 ]; then
                # INFO: Focus on outcomes and errors
                deployment_content=$(grep -iE 'successful|failed|error|warning|deployment.*complete|build.*complete|exception' "$deployment_dir" | head -8 2>/dev/null || echo "No deployment status found")
            else
                # DEBUG/VERBOSE: More detailed deployment steps
                deployment_content=$(grep -iE 'successful|failed|error|warning|deployment|build|predeployment|package|npm|dotnet|restore' "$deployment_dir" | head -12 2>/dev/null || head -8 "$deployment_dir")
            fi
            
            add_content "$deployment_content" || exit 0
            add_content "" || exit 0
            
            deployment_count=$((deployment_count + 1))
            [ $deployment_count -ge 3 ] && break
        fi
    done
    
    if [ $deployment_count -eq 0 ]; then
        add_content "No recent deployment logs found" || exit 0
        add_content "" || exit 0
    fi
fi

# =============================================================================
# DETAILED ERROR LOGS
# =============================================================================
if [ -d "$TEMP_DIR/LogFiles/DetailedErrors" ]; then
    add_content "=== Detailed Error Logs ===" || exit 0
    
    error_count=0
    for error_file in "$TEMP_DIR/LogFiles/DetailedErrors"/*; do
        if [ -f "$error_file" ] && [ $error_count -lt 5 ]; then
            add_content "--- $(basename "$error_file") ---" || exit 0
            
            # Always show detailed errors, but limit size
            if [ "$CURRENT_PRIORITY" -le 3 ]; then
                # Truncate very large error files for INFO and above
                error_content=$(head -c 2000 "$error_file")
                if [ $(wc -c < "$error_file") -gt 2000 ]; then
                    error_content="$error_content... [truncated - full error in Azure Portal]"
                fi
            else
                # Show more for DEBUG/VERBOSE
                error_content=$(head -c 4000 "$error_file")
                if [ $(wc -c < "$error_file") -gt 4000 ]; then
                    error_content="$error_content... [truncated]"
                fi
            fi
            
            add_content "$error_content" || exit 0
            add_content "" || exit 0
            
            error_count=$((error_count + 1))
        fi
    done
fi

# =============================================================================
# PERFORMANCE & API TRACES
# =============================================================================
if [ "$INCLUDE_PERFORMANCE_TRACES" = "true" ] && [ -d "$TEMP_DIR/LogFiles/kudu/trace" ] && [ "$CURRENT_PRIORITY" -ge 3 ]; then
    add_content "=== Performance Issues ===" || exit 0
    
    # Find slow requests (>5s) and failed requests
    performance_issues_found=false
    
    # Look for slow requests (files with timing indicators)
    # For INFO level: show requests >30s, for DEBUG/VERBOSE: show requests >10s
    if [ "$CURRENT_PRIORITY" -le 3 ]; then
        # INFO level: show slower requests (30s+)
        trace_files=$(find "$TEMP_DIR/LogFiles/kudu/trace" -name "*_[3-9][0-9]s.xml" -o -name "*_[0-9][0-9][0-9]s.xml" 2>/dev/null | head -5)
    else
        # DEBUG/VERBOSE: show more requests (10s+)
        trace_files=$(find "$TEMP_DIR/LogFiles/kudu/trace" -name "*_[1-9][0-9]s.xml" -o -name "*_[0-9][0-9][0-9]s.xml" 2>/dev/null | head -5)
    fi
    
    for trace_file in $trace_files; do
        if [ -f "$trace_file" ]; then
            performance_issues_found=true
            filename=$(basename "$trace_file")
            # Extract timing info from filename (simple and reliable)
            timing=$(echo "$filename" | grep -o '_[0-9]*s\.xml' | tr -d '_s.xml' || echo "unknown")
            
            # Add severity indicator based on timing
            if [ "$timing" != "unknown" ] && [ "$timing" -gt 120 ]; then
                severity="🔴 CRITICAL"
            elif [ "$timing" != "unknown" ] && [ "$timing" -gt 60 ]; then
                severity="🟠 HIGH"
            else
                severity="🟡 MEDIUM"
            fi
            
            # Simple, reliable format that works for all filename patterns
            add_content "⚠️  $severity Slow Request (${timing}s): $(echo "$filename" | cut -c1-90)" || exit 0
        fi
    done
    
    # Look for failed requests (HTTP error codes)
    for trace_file in $(find "$TEMP_DIR/LogFiles/kudu/trace" -name "*_500_*.xml" -o -name "*_404_*.xml" -o -name "*_pending.xml" 2>/dev/null | head -5); do
        if [ -f "$trace_file" ]; then
            performance_issues_found=true
            filename=$(basename "$trace_file")
            
            # Extract status code from filename (simple and reliable)
            status=$(echo "$filename" | grep -o '_[45][0-9][0-9]_' | tr -d '_' || echo "unknown")
            
            # Add error severity indicator
            if [ "$status" = "500" ]; then
                error_type="🔴 SERVER ERROR"
            elif [ "$status" = "404" ]; then
                error_type="🟡 NOT FOUND"
            elif [[ "$filename" =~ pending ]]; then
                error_type="⏳ PENDING"
            else
                error_type="🟠 CLIENT ERROR"
            fi
            
            # Simple, reliable format that works for all filename patterns
            if [[ "$filename" =~ pending ]]; then
                add_content "⏳ Pending Request: $(echo "$filename" | cut -c1-90)" || exit 0
            else
                add_content "❌ $error_type (HTTP $status): $(echo "$filename" | cut -c1-90)" || exit 0
            fi
        fi
    done
    
    if [ "$performance_issues_found" = false ]; then
        add_content "No significant performance issues detected" || exit 0
    fi
    
    add_content "" || exit 0
fi

# =============================================================================
# SYSTEM EVENT LOG (SUMMARY ONLY - AVOID VERBOSE XML)
# =============================================================================
if [ -f "$TEMP_DIR/LogFiles/eventlog.xml" ] && [ "$CURRENT_PRIORITY" -ge 4 ]; then
    add_content "=== System Events (Last 10 Events) ===" || exit 0
    if command -v xmllint &>/dev/null; then
        event_summary=$(xmllint --xpath '//Event[position()<=10]/concat("Time=", System/TimeCreated/@SystemTime, " | Level=", System/Level/text(), " | Message=", substring(RenderingInfo/Message/text(), 1, 80), "\n")' "$TEMP_DIR/LogFiles/eventlog.xml" 2>/dev/null || echo "No recent system events")
        add_content "$event_summary" || exit 0
    else
        # Fallback: simple grep for basic event info
        event_summary=$(grep -o '<TimeCreated SystemTime="[^"]*"' "$TEMP_DIR/LogFiles/eventlog.xml" | head -5 | sed 's/<TimeCreated SystemTime="//g; s/"//g' || echo "xmllint not available, skipping system events")
        add_content "Recent event timestamps: $event_summary" || exit 0
    fi
fi

# =============================================================================
# CLEANUP AND SUMMARY
# =============================================================================

echo ""
echo "📊 Enhanced Logs Summary"
echo "========================"
echo "Output size: ${output_size} bytes (Limit: ${MAX_TOTAL_SIZE} bytes)"
echo "Log level: $LOG_LEVEL"
echo "Features enabled:"
echo "  - Application Logs: ✅ (always included)"
echo "  - Docker Logs: $([ "$INCLUDE_DOCKER_LOGS" = "true" ] && echo "✅" || echo "❌")"
echo "  - Deployment History: $([ "$INCLUDE_DEPLOYMENT_LOGS" = "true" ] && echo "✅" || echo "❌")"
echo "  - Performance Traces: $([ "$INCLUDE_PERFORMANCE_TRACES" = "true" ] && echo "✅" || echo "❌")"

if [ "$max_exceeded" = true ]; then
    echo ""
    echo "⚠️  Size limit reached - some logs were truncated"
    echo "💡 To see more:"
    echo "   - Set LOG_LEVEL=ERROR for minimal output"
    echo "   - Increase MAX_TOTAL_SIZE for larger reports"
    echo "   - Disable optional features: INCLUDE_DOCKER_LOGS=false"
    echo "   - Visit Azure Portal for complete logs"
fi

echo ""
echo "🔍 For complete logs, visit: https://portal.azure.com and navigate to your App Service > Logs"

# Cleanup
rm -rf "$TEMP_DIR" "$LOG_PATH" 2>/dev/null || true 