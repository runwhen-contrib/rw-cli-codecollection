#!/bin/bash

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Get the resource ID of the Container App
resource_id=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv)

if [[ -z "$resource_id" ]]; then
    echo "Error: Container App $CONTAINER_APP_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

echo "Fetching metrics for Container App: $CONTAINER_APP_NAME"
echo "Resource ID: $resource_id"

# Define time range for metrics (last TIME_PERIOD_MINUTES minutes)
end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
start_time=$(date -u -d "${TIME_PERIOD_MINUTES} minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

issues_json='{"issues": []}'
metrics_json='{"metrics": {}}'

# Function to fetch and analyze a metric
fetch_metric() {
    local metric_name="$1"
    local threshold="$2"
    local comparison="$3"  # "gt" for greater than, "lt" for less than
    local severity="$4"
    local issue_title="$5"
    local next_step="$6"
    
    echo "Fetching $metric_name metric..."
    metric_data=$(az monitor metrics list \
        --resource "$resource_id" \
        --metrics "$metric_name" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval "PT1M" \
        --output json 2>/dev/null)
    
    if [[ -z "$metric_data" || $(echo "$metric_data" | jq '.value | length') -eq 0 ]]; then
        echo "No $metric_name data found."
        return 1
    fi
    
    # Calculate average value
    total=0
    count=0
    max_value=0
    
    while IFS= read -r data_point; do
        value=$(echo "$data_point" | jq -r '.average // .total // .maximum // empty')
        if [[ "$value" != "null" && -n "$value" ]]; then
            total=$(echo "$total + $value" | bc -l)
            count=$((count + 1))
            if (( $(echo "$value > $max_value" | bc -l) )); then
                max_value=$value
            fi
        fi
    done < <(echo "$metric_data" | jq -c '.value[].timeseries[].data[]?')
    
    if (( count > 0 )); then
        average=$(echo "$total / $count" | bc -l)
        echo "$metric_name - Average: $average, Max: $max_value, Data points: $count"
        
        # Store metric data
        metrics_json=$(echo "$metrics_json" | jq \
            --arg metric "$metric_name" \
            --arg avg "$average" \
            --arg max "$max_value" \
            --arg count "$count" \
            '.metrics[$metric] = {"average": ($avg | tonumber), "maximum": ($max | tonumber), "data_points": ($count | tonumber)}'
        )
        
        # Check threshold
        value_to_check="$average"
        if [[ "$comparison" == "max" ]]; then
            value_to_check="$max_value"
        fi
        
        if [[ "$comparison" == "gt" && $(echo "$value_to_check > $threshold" | bc -l) -eq 1 ]] || \
           [[ "$comparison" == "lt" && $(echo "$value_to_check < $threshold" | bc -l) -eq 1 ]]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "$issue_title" \
                --arg nextStep "$next_step" \
                --arg severity "$severity" \
                --arg details "$metric_name: $value_to_check (threshold: $threshold)" \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
        fi
    else
        echo "No valid data points for $metric_name"
        return 1
    fi
}

# Fetch CPU utilization
fetch_metric "CpuPercentage" "$CPU_THRESHOLD" "gt" "3" \
    "High CPU Utilization" \
    "Investigate high CPU usage for Container App $CONTAINER_APP_NAME. Consider scaling up or optimizing application performance."

# Fetch Memory utilization
fetch_metric "MemoryPercentage" "$MEMORY_THRESHOLD" "gt" "3" \
    "High Memory Utilization" \
    "Investigate high memory usage for Container App $CONTAINER_APP_NAME. Consider increasing memory limits or optimizing memory usage."

# Fetch Request count
fetch_metric "Requests" "$REQUEST_COUNT_THRESHOLD" "gt" "4" \
    "High Request Volume" \
    "Monitor high request volume for Container App $CONTAINER_APP_NAME. Consider scaling out to handle increased load."

# Fetch Restart count
fetch_metric "RestartCount" "$RESTART_COUNT_THRESHOLD" "gt" "2" \
    "High Restart Count" \
    "Investigate frequent restarts for Container App $CONTAINER_APP_NAME. Check for application crashes or resource constraints."

# Fetch HTTP response codes
fetch_metric "TotalRequests" "0" "gt" "4" \
    "Request Activity" \
    "Monitor request patterns for Container App $CONTAINER_APP_NAME."

# Check for HTTP errors if request data is available
echo "Checking for HTTP error patterns..."
http_4xx_data=$(az monitor metrics list \
    --resource "$resource_id" \
    --metrics "Http4xx" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    --interval "PT1M" \
    --output json 2>/dev/null)

http_5xx_data=$(az monitor metrics list \
    --resource "$resource_id" \
    --metrics "Http5xx" \
    --start-time "$start_time" \
    --end-time "$end_time" \
    --interval "PT1M" \
    --output json 2>/dev/null)

# Analyze HTTP error rates
if [[ -n "$http_4xx_data" && $(echo "$http_4xx_data" | jq '.value | length') -gt 0 ]]; then
    http_4xx_total=0
    http_4xx_count=0
    
    while IFS= read -r data_point; do
        value=$(echo "$data_point" | jq -r '.total // .average // empty')
        if [[ "$value" != "null" && -n "$value" ]]; then
            http_4xx_total=$(echo "$http_4xx_total + $value" | bc -l)
            http_4xx_count=$((http_4xx_count + 1))
        fi
    done < <(echo "$http_4xx_data" | jq -c '.value[].timeseries[].data[]?')
    
    if (( http_4xx_count > 0 )); then
        http_4xx_rate=$(echo "$http_4xx_total / $http_4xx_count" | bc -l)
        echo "HTTP 4xx error rate: $http_4xx_rate per minute"
        
        if (( $(echo "$http_4xx_rate > 10" | bc -l) )); then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "High HTTP 4xx Error Rate" \
                --arg nextStep "Investigate client errors for Container App $CONTAINER_APP_NAME. Check API documentation and client implementations." \
                --arg severity "4" \
                --arg details "HTTP 4xx error rate: $http_4xx_rate per minute" \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
        fi
    fi
fi

if [[ -n "$http_5xx_data" && $(echo "$http_5xx_data" | jq '.value | length') -gt 0 ]]; then
    http_5xx_total=0
    http_5xx_count=0
    
    while IFS= read -r data_point; do
        value=$(echo "$data_point" | jq -r '.total // .average // empty')
        if [[ "$value" != "null" && -n "$value" ]]; then
            http_5xx_total=$(echo "$http_5xx_total + $value" | bc -l)
            http_5xx_count=$((http_5xx_count + 1))
        fi
    done < <(echo "$http_5xx_data" | jq -c '.value[].timeseries[].data[]?')
    
    if (( http_5xx_count > 0 )); then
        http_5xx_rate=$(echo "$http_5xx_total / $http_5xx_count" | bc -l)
        echo "HTTP 5xx error rate: $http_5xx_rate per minute"
        
        if (( $(echo "$http_5xx_rate > $HTTP_ERROR_RATE_THRESHOLD" | bc -l) )); then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "High HTTP 5xx Error Rate" \
                --arg nextStep "Investigate server errors for Container App $CONTAINER_APP_NAME. Check application logs and dependencies." \
                --arg severity "2" \
                --arg details "HTTP 5xx error rate: $http_5xx_rate per minute (threshold: $HTTP_ERROR_RATE_THRESHOLD)" \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
        fi
    fi
fi

# Generate the metrics summary
summary_file="container_app_metrics_summary.txt"
echo "Metrics Summary for Container App: $CONTAINER_APP_NAME" > "$summary_file"
echo "====================================================" >> "$summary_file"
echo "Time Period: $start_time to $end_time" >> "$summary_file"
echo "" >> "$summary_file"

# Add metrics to summary
echo "$metrics_json" | jq -r '
.metrics | to_entries[] | 
"Metric: \(.key)
  Average: \(.value.average // "N/A")
  Maximum: \(.value.maximum // "N/A") 
  Data Points: \(.value.data_points // 0)
"'>> "$summary_file"

# Add thresholds info
echo "Configured Thresholds:" >> "$summary_file"
echo "  CPU Threshold: ${CPU_THRESHOLD}%" >> "$summary_file"
echo "  Memory Threshold: ${MEMORY_THRESHOLD}%" >> "$summary_file"
echo "  Request Count Threshold: ${REQUEST_COUNT_THRESHOLD}/min" >> "$summary_file"
echo "  Restart Count Threshold: ${RESTART_COUNT_THRESHOLD}" >> "$summary_file"
echo "  HTTP Error Rate Threshold: ${HTTP_ERROR_RATE_THRESHOLD}%" >> "$summary_file"

# Add issues to the summary
issue_count=$(echo "$issues_json" | jq '.issues | length')
echo "" >> "$summary_file"
echo "Issues Detected: $issue_count" >> "$summary_file"
echo "====================================================" >> "$summary_file"
echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"

# Save JSON outputs
issues_file="container_app_metrics_issues.json"
metrics_file="container_app_metrics_data.json"

echo "$issues_json" > "$issues_file"
echo "$metrics_json" > "$metrics_file"

# Final output
echo "Summary generated at: $summary_file"
echo "Metrics data saved at: $metrics_file"
echo "Issues JSON saved at: $issues_file" 