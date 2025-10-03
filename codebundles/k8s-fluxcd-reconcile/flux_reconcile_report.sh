#!/bin/bash

# Environment Variables:
# FLUX_NAMESPACE

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

SINCE_TIME="1h"
TRUNCATE_LINES=5
MAX_LINES=500

controllers=$(kubectl get --context $CONTEXT deploy -oname --no-headers -n $FLUX_NAMESPACE | grep -i controller)

echo "Generating reconcile report for Flux controllers in namespace $FLUX_NAMESPACE"
echo "For controllers: $controllers"
echo ""
total_errors=0
echo "---------------------------------------------"
for controller in $controllers; do
    echo "$controller Controller Summary"
    recent_logs=$(kubectl logs --context $CONTEXT $controller -n $FLUX_NAMESPACE --tail=$MAX_LINES --since=$SINCE_TIME)
    error_logs=$(echo "$recent_logs" | grep -i "\"level\":\"error\"")
    info_logs=$(echo "$recent_logs" | grep -i "\"level\":\"info\"")
    error_count=$(echo "$error_logs" | grep -v '^$' | wc -l)
    total_errors=$((total_errors + error_count))
    echo "Errors encountered: $error_count"
    echo ""
    echo ""
    if [ $error_count -gt 0 ]; then
        echo "Recent Error Logs:"
        echo "$error_logs" | head -n $TRUNCATE_LINES
        echo ""
        echo ""
        echo "Recent Info Logs:"
        echo "$info_logs" | head -n $TRUNCATE_LINES
    fi
    echo "---------------------------------------------"
done
echo ""
echo ""
echo "Total Errors for All Controllers: $total_errors"
echo "---------------------------------------------"
if [ $total_errors -gt 0 ]; then
    exit 1
fi
exit 0