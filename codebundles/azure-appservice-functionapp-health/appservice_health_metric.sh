#!/bin/bash

# ENV:
#   FUNCTION_APP_NAME   - Name of the Azure Function App
#   AZ_RESOURCE_GROUP   - Resource group containing the Function App
#   AZURE_RESOURCE_SUBSCRIPTION_ID - (Optional) Subscription ID (defaults to current subscription)
#   TIME_PERIOD_MINUTES - (Optional) How many minutes of data to fetch (default 5)

# Use subscription ID from environment variable
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

subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Using subscription ID: $subscription"

# Get subscription name from environment variable
subscription_name="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-5}"

# Determine the time range based on TIME_PERIOD_MINUTES
end_time=$(date -u '+%Y-%m-%dT%H:%MZ')
start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" '+%Y-%m-%dT%H:%MZ')

issues_json='{"issues": []}'
metrics_data='{"metrics": []}'

# Get the resource ID of the Function App
resource_id=$(az functionapp show \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --query "id" -o tsv 2>/dev/null)

if [[ -z "$resource_id" ]]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: Function App '$FUNCTION_APP_NAME' not found in resource group '$AZ_RESOURCE_GROUP'. (detected at $log_timestamp)"
    exit 1
fi

# Check the state of the Function App
function_app_state=$(az functionapp show \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --query "state" -o tsv)

if [[ "$function_app_state" != "Running" ]]; then
    echo "Function App '$FUNCTION_APP_NAME' is not running. Metrics may be inaccurate."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\` Not Running" \
        --arg nextStep "Ensure the Function App \`$FUNCTION_APP_NAME\` is running before collecting metrics" \
        --arg severity "2" \
        --arg details "Current state: $function_app_state for Function App '$FUNCTION_APP_NAME' in subscription '$subscription_name'" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

echo "Gathering metrics for Function App: $FUNCTION_APP_NAME"
echo "Time range: from $start_time to $end_time (UTC)"

###############################################
# List of function-related metrics we want
###############################################
declare -a FUNCTION_METRICS=(
  "FunctionExecutionCount"
  "FunctionExecutionUnits"
  "FunctionErrors"
)

# We'll store the raw metric data in a dictionary (by metric name) so we can parse each
declare -A RAW_METRIC_DATA

# Fetch each metric from Azure Monitor
for metric_name in "${FUNCTION_METRICS[@]}"; do
    echo "Querying metric: $metric_name"
    # Retrieve the metric for the specified time range. Using a 1-minute or 5-minute time grain is typical.
    metric_json=$(az monitor metrics list \
        --resource "$resource_id" \
        --metric "$metric_name" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval "PT1M" \
        --output json 2>/dev/null)

    # Store raw output in our array
    RAW_METRIC_DATA["$metric_name"]="$metric_json"

    # Append to a top-level "metrics" array in metrics_data
    # so we have a final JSON containing all raw metric results
    metrics_data=$(echo "$metrics_data" | jq \
        --arg metricName "$metric_name" \
        --argjson metricData "$metric_json" \
        '.metrics += [{"metric_name": $metricName, "raw_data": $metricData}]'
    )
done

###############################################
# Parse and check each metric
###############################################
# For demonstration, we'll do basic checks:
# - If FunctionExecutionCount == 0 over the interval => Potential issue (no invocations).
# - If FunctionErrors > 0 => Potential issue.
# - (Optional) If FunctionExecutionUnits is high => Potential cost or usage alert.

# Summaries for each metric
execution_count_total=0
execution_units_total=0
errors_total=0

for metric_name in "${FUNCTION_METRICS[@]}"; do
    metric_json="${RAW_METRIC_DATA[$metric_name]}"

    # If there's no data or the top-level array is empty, skip
    if [[ -z "$metric_json" ]] || [[ "$(echo "$metric_json" | jq '.value | length')" == "0" ]]; then
        echo "No data returned for $metric_name."
        continue
    fi

    # Flatten timeseries data
    mapfile -t data_points < <(echo "$metric_json" | jq -c '.value[].timeseries[].data[]')
    sum=0
    for point in "${data_points[@]}"; do
        # Some metrics have .average, others have .total
        val=$(echo "$point" | jq -r '.total // .average // "0"')
        # Convert to float
        if [[ "$val" == "null" ]]; then
            val=0
        fi
        sum=$(echo "$sum + $val" | bc -l)
    done

    # Assign sums to relevant variables
    case $metric_name in
        "FunctionExecutionCount")
            execution_count_total=$(echo "$execution_count_total + $sum" | bc -l)
            ;;
        "FunctionExecutionUnits")
            execution_units_total=$(echo "$execution_units_total + $sum" | bc -l)
            ;;
        "FunctionErrors")
            errors_total=$(echo "$errors_total + $sum" | bc -l)
            ;;
    esac
done

# Summaries
echo ""
echo "----- Metric Summary -----"
echo "Total Function Executions: $execution_count_total"
echo "Total Function Errors:     $errors_total"
echo "Total Execution Units:     $execution_units_total"
echo ""

###############################################
# Raise issues if thresholds are violated
###############################################

# If we have 0 executions in the entire time range, might be an issue
if (( $(echo "$execution_count_total == 0" | bc -l) )); then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Function Executions for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
        --arg nextStep "Verify that triggers are set up for Function App \`$FUNCTION_APP_NAME\` and that the function is invoked" \
        --arg severity "4" \
        --arg details "No executions recorded for '$FUNCTION_APP_NAME' in subscription '$subscription_name' over the last $TIME_PERIOD_MINUTES minute(s)." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
    )
fi

# If there were errors recorded
if (( $(echo "$errors_total > 0" | bc -l) )); then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Function Errors Detected for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
        --arg nextStep "Investigate error logs or Application Insights traces for '$FUNCTION_APP_NAME'" \
        --arg severity "2" \
        --arg details "Total errors: $errors_total for Function App '$FUNCTION_APP_NAME' in subscription '$subscription_name'" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
    )
fi

# Optionally, if you want to warn about high execution units (representing cost/usage):
if (( $(echo "$execution_units_total > 100" | bc -l) )); then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "High Function Execution Units for Function App \`$FUNCTION_APP_NAME\` in subscription \`$subscription_name\`" \
        --arg nextStep "Review cost and scaling settings for \`$FUNCTION_APP_NAME\`" \
        --arg severity "3" \
        --arg details "Execution units exceeded 100 in the last $TIME_PERIOD_MINUTES minute(s) for Function App '$FUNCTION_APP_NAME' in subscription '$subscription_name'." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
    )
fi

###############################################
# Write summary / issues to files
###############################################

summary_file="function_app_health_check_summary.txt"
issues_file="function_app_health_check_issues.json"
metrics_file="function_app_health_check_metrics.json"

echo "----- Creating summary file: $summary_file -----"
{
    echo "Function App Metrics Check"
    echo "Function App: $FUNCTION_APP_NAME"
    echo "Resource Group: $AZ_RESOURCE_GROUP"
    echo "Subscription: $subscription_name"
    echo "Time Range: $start_time to $end_time"
    echo "State: $function_app_state"
    echo ""
    echo "---- Metric Totals ----"
    echo "Executions: $execution_count_total"
    echo "Errors:     $errors_total"
    echo "Units:      $execution_units_total"
    echo ""

    issue_count=$(echo "$issues_json" | jq '.issues | length')
    echo "Issues Detected: $issue_count"
    echo ""
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"'
} > "$summary_file"

echo "----- Writing final JSON outputs -----"
echo "$issues_json"   > "$issues_file"
echo "$metrics_data" > "$metrics_file"

echo "Summary File:  $summary_file"
echo "Issues File:   $issues_file"
echo "Metrics File:  $metrics_file"
echo ""
echo "Done. Review these files for details."
