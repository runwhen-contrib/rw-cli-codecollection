#!/bin/bash

# ENV:
#   FUNCTION_APP_NAME   - Name of the Azure Function App
#   AZ_RESOURCE_GROUP   - Resource group containing the Function App
#   AZURE_RESOURCE_SUBSCRIPTION_ID - (Optional) Subscription ID (defaults to current subscription)
#   RW_LOOKBACK_WINDOW - (Optional) How many minutes of data to fetch (default 5)

# Use subscription ID from environment variable
subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
echo "Using subscription ID: $subscription"

# Get subscription name from environment variable
subscription_name="${AZURE_SUBSCRIPTION_NAME:-Unknown}"

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

RW_LOOKBACK_WINDOW="${RW_LOOKBACK_WINDOW:-5}"

# Determine the time range based on RW_LOOKBACK_WINDOW
end_time=$(date -u '+%Y-%m-%dT%H:%MZ')
start_time=$(date -u -d "$RW_LOOKBACK_WINDOW minutes ago" '+%Y-%m-%dT%H:%MZ')

issues_json='{"issues": []}'
metrics_data='{"metrics": []}'

# Get the resource ID of the Function App
resource_id=$(az functionapp show \
    --name "$FUNCTION_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --query "id" -o tsv 2>/dev/null)

if [[ -z "$resource_id" ]]; then
    echo "Error: Function App '$FUNCTION_APP_NAME' not found in resource group '$AZ_RESOURCE_GROUP'."
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
        --arg details "No executions recorded for '$FUNCTION_APP_NAME' in subscription '$subscription_name' over the last $RW_LOOKBACK_WINDOW minute(s)." \
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

# Advanced execution units analysis with baseline comparison and anomaly detection
echo "🔍 Analyzing execution units with baseline comparison..."

# Get configuration values with defaults
COST_THRESHOLD=${EXECUTION_UNITS_COST_THRESHOLD:-10000000}
ANOMALY_MULTIPLIER=${EXECUTION_UNITS_ANOMALY_MULTIPLIER:-5}
LOOKBACK_DAYS=${BASELINE_LOOKBACK_DAYS:-7}

# Calculate baseline from historical data (same time period, N days ago)
echo "📊 Calculating baseline from last $LOOKBACK_DAYS days..."

# Calculate historical time range (same duration, N days ago)
baseline_end_time=$(date -u -d "$LOOKBACK_DAYS days ago" -d "$end_time" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
baseline_start_time=$(date -u -d "$LOOKBACK_DAYS days ago" -d "$start_time" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")

baseline_execution_units=0
baseline_available=false

# Only attempt baseline calculation if we have valid dates
if [[ -n "$baseline_start_time" && -n "$baseline_end_time" ]]; then
    echo "Baseline period: $baseline_start_time to $baseline_end_time"
    
    # Get historical execution units for baseline
    baseline_metric_data=$(az monitor metrics list \
        --resource "$FUNCTION_APP_ID" \
        --metric "FunctionExecutionUnits" \
        --start-time "$baseline_start_time" \
        --end-time "$baseline_end_time" \
        --interval PT5M \
        --output json 2>/dev/null || echo '{"value":[]}')
    
    # Calculate baseline total
    if [[ -n "$baseline_metric_data" ]] && [[ "$(echo "$baseline_metric_data" | jq '.value | length')" != "0" ]]; then
        mapfile -t baseline_points < <(echo "$baseline_metric_data" | jq -c '.value[].timeseries[].data[]')
        baseline_sum=0
        baseline_count=0
        
        for point in "${baseline_points[@]}"; do
            val=$(echo "$point" | jq -r '.total // "0"')
            if [[ "$val" != "null" && "$val" != "0" ]]; then
                baseline_sum=$(echo "$baseline_sum + $val" | bc -l 2>/dev/null || echo "$baseline_sum")
                baseline_count=$((baseline_count + 1))
            fi
        done
        
        if [[ $baseline_count -gt 0 ]]; then
            baseline_execution_units=$baseline_sum
            baseline_available=true
            echo "✅ Baseline calculated: $baseline_execution_units execution units ($baseline_count data points)"
        else
            echo "⚠️ No baseline data available - using fallback thresholds"
        fi
    else
        echo "⚠️ No historical data available for baseline calculation"
    fi
else
    echo "⚠️ Could not calculate baseline time range"
fi

# Cost threshold check (always performed)
if (( $(echo "$execution_units_total > $COST_THRESHOLD" | bc -l) )); then
    monthly_cost_estimate=$(echo "scale=2; $execution_units_total * 0.000016 * 30 * 24 * 6" | bc -l 2>/dev/null || echo "unknown")
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "High Function Execution Units Cost Alert for \`$FUNCTION_APP_NAME\`" \
        --arg nextStep "Review cost and scaling settings for \`$FUNCTION_APP_NAME\`. Consider optimizing function memory allocation, execution time, or implementing scaling policies." \
        --arg severity "4" \
        --arg details "COST ALERT: Execution units ($execution_units_total) exceeded cost threshold ($COST_THRESHOLD) in the last $RW_LOOKBACK_WINDOW minute(s) for Function App '$FUNCTION_APP_NAME'. Estimated monthly cost impact: ~\$$monthly_cost_estimate. Current usage represents significant compute costs that should be reviewed." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
    )
fi

# Anomaly detection (only if baseline is available)
if [[ "$baseline_available" == "true" ]]; then
    anomaly_threshold=$(echo "$baseline_execution_units * $ANOMALY_MULTIPLIER" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$execution_units_total > $anomaly_threshold" | bc -l) )); then
        multiplier_actual=$(echo "scale=1; $execution_units_total / $baseline_execution_units" | bc -l 2>/dev/null || echo "unknown")
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Execution Units Anomaly Detected for \`$FUNCTION_APP_NAME\`" \
            --arg nextStep "Investigate unusual activity: check for traffic spikes, function performance issues, memory leaks, or deployment changes. Review Application Insights for \`$FUNCTION_APP_NAME\`." \
            --arg severity "3" \
            --arg details "ANOMALY ALERT: Current execution units ($execution_units_total) are ${multiplier_actual}x higher than baseline ($baseline_execution_units) for Function App '$FUNCTION_APP_NAME'. This represents unusual activity compared to the same time period $LOOKBACK_DAYS days ago. Potential causes: traffic spike, performance regression, memory leaks, or inefficient code changes." \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity|tonumber), "details": $details}]'
        )
    else
        echo "✅ Execution units within normal range (${execution_units_total} vs baseline ${baseline_execution_units})"
    fi
else
    echo "ℹ️ Anomaly detection skipped - no baseline available (new app or insufficient historical data)"
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
