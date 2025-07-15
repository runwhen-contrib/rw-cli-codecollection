#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP
# TIME_PERIOD_MINUTES (Optional, default is 60)


# Set the default time period to 60 minutes if not provided
TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-60}"

# Get subscription name for issue reporting
subscription_name="${AZURE_SUBSCRIPTION_NAME:-$(az account show --query "name" -o tsv 2>/dev/null || echo "Unknown")}"

# Convert TIME_PERIOD_MINUTES into ISO 8601 duration format
if (( TIME_PERIOD_MINUTES < 60 )); then
    duration="PT${TIME_PERIOD_MINUTES}M"
elif (( TIME_PERIOD_MINUTES < 1440 )); then
    hours=$(( TIME_PERIOD_MINUTES / 60 ))
    minutes=$(( TIME_PERIOD_MINUTES % 60 ))
    duration="PT${hours}H${minutes}M"
else
    days=$(( TIME_PERIOD_MINUTES / 1440 ))
    hours=$(( (TIME_PERIOD_MINUTES % 1440) / 60 ))
    minutes=$(( TIME_PERIOD_MINUTES % 60 ))
    duration="P${days}DT${hours}H${minutes}M"
fi

start_time=$(date -u -d "$TIME_PERIOD_MINUTES minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

tenant_id=$(az account show --query "tenantId" -o tsv)
subscription_id=$(az account show --query "id" -o tsv)

# Log in to Azure CLI (uncomment if needed)
# az login --service-principal --username "$AZ_USERNAME" --password "$AZ_SECRET_VALUE" --tenant "$AZ_TENANT" > /dev/null
# az account set --subscription "$AZ_SUBSCRIPTION"

# Remove previous issues and metrics files if they exist
[ -f "app_service_issues.json" ] && rm "app_service_issues.json"
[ -f "app_service_metrics.json" ] && rm "app_service_metrics.json"

# Configurable time range for metrics (default to last 30 minutes for efficiency)
METRICS_TIME_HOURS="${METRICS_TIME_HOURS:-0.5}"
MAX_METRIC_POINTS="${MAX_METRIC_POINTS:-6}"         # Only 6 data points (5-minute intervals)

# Set time range based on configuration
if [[ "$METRICS_TIME_HOURS" == "0.5" ]]; then
    start_time=$(date -u -d "30 minutes ago" '+%Y-%m-%dT%H:%M:%SZ')
else
    start_time=$(date -u -d "$METRICS_TIME_HOURS hours ago" '+%Y-%m-%dT%H:%M:%SZ')
fi
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

echo "Metrics Collection Configuration:"
echo "- Time range: Last ${METRICS_TIME_HOURS} hours"
echo "- Maximum data points per metric: ${MAX_METRIC_POINTS}"
echo "- Start time: $start_time"
echo "- End time: $end_time"

# Get subscription name for issue reporting
subscription_name="${AZURE_SUBSCRIPTION_NAME:-$(az account show --query "name" -o tsv 2>/dev/null || echo "Unknown")}"

# Initialize JSON structures - ensure we always have valid output
issues_json='{"issues": []}'
metrics_json='{"metrics": []}'

# Set thresholds for various metrics
CPU_THRESHOLD=${CPU_THRESHOLD:-30000}  # milliseconds
REQUESTS_THRESHOLD=${REQUESTS_THRESHOLD:-1000}  # requests per minute
BYTES_RECEIVED_THRESHOLD=${BYTES_RECEIVED_THRESHOLD:-20971520}  # 20MB
HTTP5XX_THRESHOLD=${HTTP5XX_THRESHOLD:-50}  # server errors per minute
HTTP2XX_THRESHOLD=${HTTP2XX_THRESHOLD:-10}  # minimum successful requests
HTTP4XX_THRESHOLD=${HTTP4XX_THRESHOLD:-100}  # client errors per minute
DISK_USAGE_THRESHOLD=${DISK_USAGE_THRESHOLD:-90}  # percentage
AVG_RSP_TIME=${AVG_RSP_TIME:-5000}  # milliseconds

echo "Azure App Service $APP_SERVICE_NAME metrics usage analysis:"

# Get the resource ID of the App Service
if ! resource_id=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null); then
    echo "Error: App Service $APP_SERVICE_NAME not found in resource group $AZ_RESOURCE_GROUP."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` Not Found in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$subscription_name\`)" \
        --arg details "Could not find App Service \`$APP_SERVICE_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` in subscription \`$subscription_name\`. Service may not exist or access may be restricted." \
        --arg nextStep "Verify App Service name and resource group, or check access permissions for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$subscription_name\`" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    
    # Save outputs and exit
    echo "$issues_json" > "app_service_issues.json"
    echo "$metrics_json" > "app_service_metrics.json"
    
    # Generate summary
    echo "Azure App Service Metrics Summary" > "app_service_metrics_summary.txt"
    echo "=================================" >> "app_service_metrics_summary.txt"
    echo "App Service: $APP_SERVICE_NAME" >> "app_service_metrics_summary.txt"
    echo "Resource Group: $AZ_RESOURCE_GROUP" >> "app_service_metrics_summary.txt"
    echo "Subscription: $subscription_name" >> "app_service_metrics_summary.txt"
    echo "Status: Not Found" >> "app_service_metrics_summary.txt"
    echo "Issues Detected: 1" >> "app_service_metrics_summary.txt"
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "app_service_metrics_summary.txt"
    
    echo "App Service not found. Results saved to app_service_issues.json"
    exit 0
fi

# Check if resource ID is found
if [[ -z "$resource_id" ]]; then
    echo "Error: Empty resource ID returned for App Service $APP_SERVICE_NAME."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Empty Resource ID for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$subscription_name\`)" \
        --arg details "App Service query returned empty resource ID for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$subscription_name\`. Service may not exist." \
        --arg nextStep "Verify App Service \`$APP_SERVICE_NAME\` exists in resource group \`$AZ_RESOURCE_GROUP\` in subscription \`$subscription_name\`" \
        --arg severity "1" \
        '.issues += [{"title": $title, "details": $details, "next_step": $nextStep, "severity": ($severity | tonumber)}]')
    
    # Save outputs and exit
    echo "$issues_json" > "app_service_issues.json"
    echo "$metrics_json" > "app_service_metrics.json"
    
    # Generate summary
    echo "Azure App Service Metrics Summary" > "app_service_metrics_summary.txt"
    echo "=================================" >> "app_service_metrics_summary.txt"
    echo "App Service: $APP_SERVICE_NAME" >> "app_service_metrics_summary.txt"
    echo "Resource Group: $AZ_RESOURCE_GROUP" >> "app_service_metrics_summary.txt"
    echo "Subscription: $subscription_name" >> "app_service_metrics_summary.txt"
    echo "Status: Empty Resource ID" >> "app_service_metrics_summary.txt"
    echo "Issues Detected: 1" >> "app_service_metrics_summary.txt"
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "app_service_metrics_summary.txt"
    
    echo "Empty resource ID. Results saved to app_service_issues.json"
    exit 0
fi

# Check the status of the App Service
app_service_state=$(az webapp show --name "$APP_SERVICE_NAME" --resource-group "$AZ_RESOURCE_GROUP" --query "state" -o tsv 2>/dev/null)

if [[ "$app_service_state" != "Running" ]]; then
    echo "CRITICAL: App Service $APP_SERVICE_NAME is $app_service_state (not running)!"
    portal_url="https://portal.azure.com/#@/resource${resource_id}/overview"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "App Service \`$APP_SERVICE_NAME\` is $app_service_state (Not Running) in \`$AZ_RESOURCE_GROUP\` (Subscription: \`$subscription_name\`)" \
        --arg nextStep "Start the App Service \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\` in subscription \`$subscription_name\` immediately to restore service availability." \
        --arg severity "1" \
        --arg details "App Service state: $app_service_state. Service is unavailable to users. Portal URL: $portal_url" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
    
    # Generate summary for stopped service
    echo "Azure App Service Metrics Summary" > "app_service_metrics_summary.txt"
    echo "=================================" >> "app_service_metrics_summary.txt"
    echo "App Service: $APP_SERVICE_NAME" >> "app_service_metrics_summary.txt"
    echo "Resource Group: $AZ_RESOURCE_GROUP" >> "app_service_metrics_summary.txt"
    echo "Subscription: $subscription_name" >> "app_service_metrics_summary.txt"
    echo "Status: $app_service_state (STOPPED)" >> "app_service_metrics_summary.txt"
    echo "Issues Detected: 1 (CRITICAL)" >> "app_service_metrics_summary.txt"
    echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "app_service_metrics_summary.txt"
    
    # Save outputs and exit
    echo "$issues_json" > "app_service_issues.json"
    echo "$metrics_json" > "app_service_metrics.json"
    
    echo "App Service is stopped. Results saved to app_service_issues.json"
    exit 0
fi

# List of metrics to fetch (optimized with better time intervals)
metrics=(
    "CpuTime"
    "Requests"
    "BytesReceived"
    "BytesSent"
    "Http5xx"
    "Http2xx"
    "Http4xx"
    "Threads"
    "FileSystemUsage"
    "AverageResponseTime"
)

# Time grain adjustment for specific metrics
declare -A metric_time_grains
metric_time_grains=(
    ["FileSystemUsage"]="06:00:00"
)

# Loop through each metric and fetch data
for metric in "${metrics[@]}"; do
    echo "Fetching metric: $metric"

    # Use 5-minute intervals for efficiency (PT5M)
    time_grain="PT5M"
    if [[ -n "${metric_time_grains[$metric]}" ]]; then
        time_grain="${metric_time_grains[$metric]}"
    fi

    # Fetch the metric data
    if metric_data=$(az monitor metrics list \
        --resource "$resource_id" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval "$time_grain" \
        --metrics "$metric" \
        --output json 2>/dev/null); then
        
        if [[ -z "$metric_data" || $(echo "$metric_data" | jq '.value | length') -eq 0 ]]; then
            echo "No data found for metric: $metric"
            continue
        fi

        # Initialize aggregation variables
        total=0
        count=0
        max=-1
        min=-1

        # Process timeseries data
        echo "$metric_data" | jq -c ".value[].timeseries[] | .data[]" | while read -r data_point; do
            timestamp=$(echo "$data_point" | jq -r '.timeStamp')
            value=$(echo "$data_point" | jq -r '.total // .average')

            # Skip if value is null
            if [[ "$value" == "null" ]]; then
                continue
            fi

            # Accumulate values for summary
            total=$(echo "$total + $value" | bc -l)
            count=$((count + 1))
            if (( $(echo "$value > $max" | bc -l) )); then max=$value; fi
            if [[ $min == -1 || $(echo "$value < $min" | bc -l) -eq 1 ]]; then min=$value; fi

            # Add issues based on thresholds
            if [[ "$metric" == "CpuTime" && $(echo "$value > $CPU_THRESHOLD" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High CPU Time Usage" \
                    --arg nextStep "Investigate high CPU usage for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "2" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "Requests" && $(echo "$value > $REQUESTS_THRESHOLD" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High Number of Requests" \
                    --arg nextStep "Analyze traffic patterns and optimize handling for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "3" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "BytesReceived" && $(echo "$value > 10485760" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High Incoming Bandwidth" \
                    --arg nextStep "Investigate large data transfers for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "3" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "BytesSent" && $(echo "$value > BYTES_RECEIVED_THRESHOLD" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High Outgoing Bandwidth" \
                    --arg nextStep "Check outgoing traffic from \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "3" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "Http5xx" && $(echo "$value > $HTTP5XX_THRESHOLD" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High Server Error Rate" \
                    --arg nextStep "Review server errors for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "1" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "Http2xx" && $(echo "$value < $HTTP2XX_THRESHOLD" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Low Successful Requests" \
                    --arg nextStep "Investigate low success rates for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "2" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "Http4xx" && $(echo "$value > 50" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High Client Error Rate" \
                    --arg nextStep "Review client-side errors for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "2" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "Threads" && $(echo "$value > $HTTP4XX_THRESHOLD" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High Thread Count" \
                    --arg nextStep "Investigate thread usage for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "3" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "FileSystemUsage" && $(echo "$value > $DISK_USAGE_THRESHOLD" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High File System Usage" \
                    --arg nextStep "Increase storage capacity or cleanup for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "2" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            elif [[ "$metric" == "AverageResponseTime" && $(echo "$value > $AVG_RSP_TIME" | bc -l) -eq 1 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "High Average Response Time" \
                    --arg nextStep "Optimize response times for \`$APP_SERVICE_NAME\` in \`$AZ_RESOURCE_GROUP\`." \
                    --arg severity "2" \
                    --arg details "Metric: $metric, Value: $value, Timestamp: $timestamp" \
                    '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
            fi
        done

        # Calculate average and ensure meaningful defaults for empty data
        if (( count > 0 )); then
            average=$(echo "$total / $count" | bc -l)
        else
            average=0
            min=0
            max=0
        fi

        # Add metric details to metrics JSON
        metrics_json=$(echo "$metrics_json" | jq \
            --arg name "$metric" \
            --argjson total "$total" \
            --argjson count "$count" \
            --argjson average "$average" \
            --argjson max "$max" \
            --argjson min "$min" \
            '.metrics += [{"name": $name, "total": $total, "count": $count, "average": $average, "max": $max, "min": $min}]')
    else
        echo "Warning: Could not fetch metric $metric"
    fi
done

# Always save the metrics JSON data
metrics_file="app_service_metrics.json"
echo "$metrics_json" > "$metrics_file"

# Always save the issues JSON data
issues_file="app_service_issues.json"
echo "$issues_json" > "$issues_file"

# Generate a human-readable summary
echo "Generating human-readable summary..."
summary_file="app_service_metrics_summary.txt"
echo "Azure App Service Metrics Summary" > "$summary_file"
echo "=================================" >> "$summary_file"
echo >> "$summary_file"

# Add metrics details to the summary
echo "$metrics_json" | jq -r '.metrics[] | "Metric: \(.name)\n  Total: \(.total)\n  Count: \(.count)\n  Average: \(.average)\n  Max: \(.max)\n  Min: \(.min)\n"' >> "$summary_file"

# Add issues to the summary
issue_count=$(echo "$issues_json" | jq '.issues | length')
echo "Issues Detected: $issue_count" >> "$summary_file"

echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"

# Final output
echo "Summary generated at: $summary_file"
echo "Metrics JSON saved at: $metrics_file"
echo "Issues JSON saved at: $issues_file"