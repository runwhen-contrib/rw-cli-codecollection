#!/usr/bin/env bash
#
# Check APIM Application Insights Integration and Analyze Telemetry
#
# Usage:
#   export AZ_RESOURCE_GROUP="myResourceGroup"
#   export APIM_NAME="myApimInstance"
#   export TIME_PERIOD_MINUTES="60"  # Optional, defaults to 60
#   # Optional: export AZURE_RESOURCE_SUBSCRIPTION_ID="your-subscription-id"
#   ./check_apim_appinsights.sh
#
# Description:
#   - Checks if APIM has Application Insights configured
#   - If configured, analyzes telemetry for errors and performance issues
#   - If not configured, notes it as informational (not an error)
#   - Reports on exceptions, failed requests, and performance degradation

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

set -euo pipefail

###############################################################################
# 1) Subscription context & environment checks
###############################################################################
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || {
    echo "Failed to set subscription."
    exit 1
}

: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"
: "${APIM_NAME:?Must set APIM_NAME}"

TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-60}"
OUTPUT_FILE="apim_appinsights_issues.json"
issues_json='{"issues": []}'

echo "[INFO] Checking APIM Application Insights Integration..."
echo " APIM Name:     $APIM_NAME"
echo " ResourceGroup: $AZ_RESOURCE_GROUP"
echo " Time Period:   $TIME_PERIOD_MINUTES minutes"

###############################################################################
# 2) Check if APIM has Application Insights configured
###############################################################################
echo "[INFO] Checking APIM Application Insights configuration..."

if ! apim_json=$(az apim show \
      --name "$APIM_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      -o json 2>apim_show_err.log); then
    err_msg=$(cat apim_show_err.log)
    rm -f apim_show_err.log
    echo "ERROR: Could not retrieve APIM details."
    issues_json=$(echo "$issues_json" | jq \
        --arg t "Failed to Retrieve APIM Resource" \
        --arg d "$err_msg" \
        --arg s "1" \
        --arg n "Check APIM name/RG and permissions." \
        '.issues += [{
           "title": $t,
           "details": $d,
           "next_steps": $n,
           "severity": ($s | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f apim_show_err.log

# Check for Application Insights configuration
app_insights_id=$(echo "$apim_json" | jq -r '.properties.loggerProps?.azureApplicationInsights?.resourceId? // empty')
app_insights_instrumentation_key=$(echo "$apim_json" | jq -r '.properties.loggerProps?.azureApplicationInsights?.instrumentationKey? // empty')

if [[ -z "$app_insights_id" && -z "$app_insights_instrumentation_key" ]]; then
    echo "[INFO] No Application Insights integration configured for APIM."
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "[INFO] Application Insights integration found."
if [[ -n "$app_insights_id" ]]; then
    echo "  Resource ID: $app_insights_id"
fi

###############################################################################
# 3) Get Application Insights workspace ID for queries
###############################################################################
if [[ -n "$app_insights_id" ]]; then
    # Get Application Insights details
    if ! app_insights_details=$(az monitor app-insights component show \
          --ids "$app_insights_id" \
          -o json 2>ai_err.log); then
        err_msg=$(cat ai_err.log)
        rm -f ai_err.log
        echo "[WARN] Could not retrieve Application Insights details."
        issues_json=$(echo "$issues_json" | jq \
            --arg t "Application Insights Not Accessible" \
            --arg d "Configured but cannot access: $err_msg" \
            --arg s "3" \
            --arg n "Check permissions to Application Insights resource." \
            '.issues += [{
               "title": $t,
               "details": $d,
               "next_steps": $n,
               "severity": ($s | tonumber)
            }]')
        echo "$issues_json" > "$OUTPUT_FILE"
        exit 0
    fi
    rm -f ai_err.log
    
    app_name=$(echo "$app_insights_details" | jq -r '.name')
    echo "[INFO] Application Insights: $app_name"
else
    echo "[INFO] Using instrumentation key for legacy Application Insights"
    # For legacy configurations, we'd need to find the App Insights by instrumentation key
    # This is more complex and not always reliable, so we'll note it
    issues_json=$(echo "$issues_json" | jq \
        --arg t "Legacy Application Insights Configuration" \
        --arg d "APIM uses instrumentation key instead of resource ID. Advanced telemetry analysis not available." \
        --arg s "4" \
        --arg n "Note: Consider updating to resource ID-based Application Insights integration." \
        '.issues += [{
           "title": $t,
           "details": $d,
           "next_steps": $n,
           "severity": ($s | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 0
fi

###############################################################################
# 4) Query Application Insights for APIM-related issues
###############################################################################
echo "[INFO] Analyzing Application Insights telemetry..."

# Calculate time range
start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" +"%Y-%m-%dT%H:%M:%SZ")
end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Query for exceptions related to APIM
EXCEPTIONS_QUERY="exceptions
| where timestamp >= datetime('$start_time') and timestamp <= datetime('$end_time')
| where cloud_RoleName has \"$APIM_NAME\" or operation_Name has \"apim\" or operation_Name has \"gateway\"
| summarize ExceptionCount = count() by type, outerMessage
| order by ExceptionCount desc"

echo "[INFO] Querying Application Insights for exceptions..."
if exceptions_output=$(az monitor app-insights query \
      --app "$app_insights_id" \
      --analytics-query "$EXCEPTIONS_QUERY" \
      -o json 2>ai_query_err.log); then
    
    exception_count=$(echo "$exceptions_output" | jq '.tables[0].rows | length')
    if [[ "$exception_count" -gt 0 ]]; then
        echo "[INFO] Found $exception_count exception types"
        
        # Process exceptions
        for (( i=0; i<exception_count; i++ )); do
            exc_type=$(echo "$exceptions_output" | jq -r ".tables[0].rows[$i][0] // \"Unknown\"")
            exc_message=$(echo "$exceptions_output" | jq -r ".tables[0].rows[$i][1] // \"No message\"")
            exc_count=$(echo "$exceptions_output" | jq -r ".tables[0].rows[$i][2] // 0")
            
            if [[ "$exc_count" -gt 5 ]]; then  # Threshold for reporting
                issues_json=$(echo "$issues_json" | jq \
                    --arg t "Frequent Exceptions in Application Insights" \
                    --arg d "Exception: $exc_type, Message: $exc_message, Count: $exc_count" \
                    --arg s "2" \
                    --arg n "Investigate $exc_type exceptions in APIM. Check application logs and policies." \
                    '.issues += [{
                       "title": $t,
                       "details": $d,
                       "next_steps": $n,
                       "severity": ($s | tonumber)
                    }]')
            fi
        done
    fi
else
    err_msg=$(cat ai_query_err.log)
    rm -f ai_query_err.log
    echo "[WARN] Could not query Application Insights for exceptions: $err_msg"
fi

# Query for failed requests
FAILED_REQUESTS_QUERY="requests
| where timestamp >= datetime('$start_time') and timestamp <= datetime('$end_time')
| where cloud_RoleName has \"$APIM_NAME\" or operation_Name has \"apim\" or operation_Name has \"gateway\"
| where success == false
| summarize FailedCount = count() by resultCode, name
| order by FailedCount desc"

echo "[INFO] Querying Application Insights for failed requests..."
if failed_requests_output=$(az monitor app-insights query \
      --app "$app_insights_id" \
      --analytics-query "$FAILED_REQUESTS_QUERY" \
      -o json 2>ai_query_err.log); then
    
    failed_request_types=$(echo "$failed_requests_output" | jq '.tables[0].rows | length')
    if [[ "$failed_request_types" -gt 0 ]]; then
        echo "[INFO] Found $failed_request_types failed request types"
        
        # Process failed requests
        total_failures=0
        for (( i=0; i<failed_request_types; i++ )); do
            result_code=$(echo "$failed_requests_output" | jq -r ".tables[0].rows[$i][0] // \"Unknown\"")
            operation_name=$(echo "$failed_requests_output" | jq -r ".tables[0].rows[$i][1] // \"Unknown\"")
            fail_count=$(echo "$failed_requests_output" | jq -r ".tables[0].rows[$i][2] // 0")
            total_failures=$((total_failures + fail_count))
        done
        
        if [[ "$total_failures" -gt 10 ]]; then  # Threshold for reporting
            failure_details=$(echo "$failed_requests_output" | jq -c '.tables[0].rows')
            issues_json=$(echo "$issues_json" | jq \
                --arg t "High Number of Failed Requests in Application Insights" \
                --arg d "Total failed requests: $total_failures. Details: $failure_details" \
                --arg s "2" \
                --arg n "Investigate failed request patterns in APIM. Check API policies and backend connectivity." \
                '.issues += [{
                   "title": $t,
                   "details": $d,
                   "next_steps": $n,
                   "severity": ($s | tonumber)
                }]')
        fi
    fi
else
    err_msg=$(cat ai_query_err.log)
    rm -f ai_query_err.log
    echo "[WARN] Could not query Application Insights for failed requests: $err_msg"
fi

# Query for performance issues
PERFORMANCE_QUERY="requests
| where timestamp >= datetime('$start_time') and timestamp <= datetime('$end_time')
| where cloud_RoleName has \"$APIM_NAME\" or operation_Name has \"apim\" or operation_Name has \"gateway\"
| summarize AvgDuration = avg(duration), MaxDuration = max(duration), RequestCount = count()
| where AvgDuration > 1000 or MaxDuration > 5000"  # 1 second average or 5 second max

echo "[INFO] Querying Application Insights for performance issues..."
if performance_output=$(az monitor app-insights query \
      --app "$app_insights_id" \
      --analytics-query "$PERFORMANCE_QUERY" \
      -o json 2>ai_query_err.log); then
    
    perf_issues=$(echo "$performance_output" | jq '.tables[0].rows | length')
    if [[ "$perf_issues" -gt 0 ]]; then
        avg_duration=$(echo "$performance_output" | jq -r '.tables[0].rows[0][0] // 0')
        max_duration=$(echo "$performance_output" | jq -r '.tables[0].rows[0][1] // 0')
        request_count=$(echo "$performance_output" | jq -r '.tables[0].rows[0][2] // 0')
        
        issues_json=$(echo "$issues_json" | jq \
            --arg t "Performance Issues Detected in Application Insights" \
            --arg d "Average duration: ${avg_duration}ms, Max duration: ${max_duration}ms, Request count: $request_count" \
            --arg s "3" \
            --arg n "Investigate APIM performance issues. Check policies, backend response times, and network latency." \
            '.issues += [{
               "title": $t,
               "details": $d,
               "next_steps": $n,
               "severity": ($s | tonumber)
            }]')
    fi
else
    err_msg=$(cat ai_query_err.log)
    rm -f ai_query_err.log
    echo "[WARN] Could not query Application Insights for performance data: $err_msg"
fi

rm -f ai_query_err.log

###############################################################################
# 5) Final JSON output
###############################################################################
echo "$issues_json" > "$OUTPUT_FILE"
echo "[INFO] APIM Application Insights check complete. Results -> $OUTPUT_FILE" 