#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# APP_SERVICE_NAME
# AZ_RESOURCE_GROUP
# OUTPUT_DIR
# TIME_PERIOD_MINUTES (Optional, default is 60)

# Ensure OUTPUT_DIR is set
: "${OUTPUT_DIR:?OUTPUT_DIR variable is not set}"

# Set the default time period to 60 minutes if not provided
TIME_PERIOD_MINUTES="${TIME_PERIOD_MINUTES:-0}"

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

# Remove previous metrics.json file if it exists
[ -f "$OUTPUT_DIR/metrics.json" ] && rm "$OUTPUT_DIR/metrics.json"

echo "Azure App Service $APP_SERVICE_NAME metrics usage analysis:"

# Get the resource ID of the App Service
resource_id=$(az webapp show --name $APP_SERVICE_NAME --resource-group $AZ_RESOURCE_GROUP --query "id" -o tsv)

# Check if resource ID is found
if [[ -z "$resource_id" ]]; then
    echo "Error: App Service $APP_SERVICE_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

# Initialize JSON object
metrics_json=$(jq -n '{metrics: []}')

# List of metrics to fetch
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

# Initialize summary dictionary
declare -A metric_summaries

# Loop through each metric and fetch data
for metric in "${metrics[@]}"; do
    echo "Fetching metric: $metric"

    # Adjust time grain if required
    time_grain="PT1M"
    if [[ -n "${metric_time_grains[$metric]}" ]]; then
        time_grain="${metric_time_grains[$metric]}"
    fi

    # Fetch the metric data
    metric_data=$(az monitor metrics list \
        --resource "$resource_id" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval "$time_grain" \
        --metrics "$metric" \
        --output json 2>/dev/null)

    if [[ -z "$metric_data" || $(echo "$metric_data" | jq '.value | length') -eq 0 ]]; then
        echo "No data found for metric: $metric"
        continue
    fi

    # Initialize aggregation variables
    total=0
    count=0
    max=-1
    min=-1
    alerts=0

    # Process timeseries data in chunks
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

        # Determine if alert is triggered
        if [[ "$metric" == "CpuTime" && $(echo "$value > 80" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "Requests" && $(echo "$value > 1000" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "BytesReceived" && $(echo "$value > 10485760" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "BytesSent" && $(echo "$value > 10485760" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "Http5xx" && $(echo "$value > 5" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "Http2xx" && $(echo "$value < 50" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "Http4xx" && $(echo "$value > 50" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "Threads" && $(echo "$value > 200" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "FileSystemUsage" && $(echo "$value > 90" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
        elif [[ "$metric" == "AverageResponseTime" && $(echo "$value > 300" | bc -l) -eq 1 ]]; then
            alerts=$((alerts + 1))
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

    # Store summary for the metric
    metric_summaries[$metric]="Total: $total, Count: $count, Average: $average, Max: $max, Min: $min, Alerts: $alerts"

done

# Save the metrics JSON data
metrics_file="$OUTPUT_DIR/app_service_metrics.json"
echo "$metrics_json" > "$metrics_file"

# Generate a human-readable summary
echo "Generating human-readable summary..."
summary_file="$OUTPUT_DIR/app_service_metrics_summary.txt"
echo "Azure App Service Metrics Summary" > "$summary_file"
echo "=================================" >> "$summary_file"
echo >> "$summary_file"

# Add summaries to the file
for metric in "${!metric_summaries[@]}"; do
    echo "Metric: $metric" >> "$summary_file"
    echo "${metric_summaries[$metric]}" >> "$summary_file"
    echo >> "$summary_file"
done

echo "Summary generated at: $summary_file"
echo "Metrics analysis completed. Results saved to $metrics_file and summary saved to $summary_file"
