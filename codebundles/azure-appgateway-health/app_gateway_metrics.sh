#!/usr/bin/env bash
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

# -----------------------------------------------------------------------------
# Hardcoded aggregator mappings. 
# Adjust to the aggregators that work best for your environment:
#   - "TotalRequests"       => "Average"
#   - "FailedRequests"      => "Average"
#   - "UnhealthyHostCount"  => "Average"
#   - "HealthyHostCount"    => "Average"
#   - "CurrentConnections"  => "Average"
#   - "Throughput"          => "Average"
#   - "ClientRtt"           => "Average"
#   - "BackendConnectTime"  => "Average"
# -----------------------------------------------------------------------------
declare -A METRIC_TO_AGGREGATOR=(
  ["TotalRequests"]="Average"
  ["FailedRequests"]="Average"
  ["UnhealthyHostCount"]="Average"
  ["HealthyHostCount"]="Average"
  ["CurrentConnections"]="Average"
  ["Throughput"]="Average"
  ["ClientRtt"]="Average"
  ["BackendConnectTime"]="Average"
)

# -----------------------------------------------------------------------------
# Metrics you want to query
# -----------------------------------------------------------------------------
METRICS_TO_FETCH=(
  "TotalRequests"
  "FailedRequests"
  "UnhealthyHostCount"
  "HealthyHostCount"
  "CurrentConnections"
  "Throughput"
  "ClientRtt"
  "BackendConnectTime"
)

# -----------------------------------------------------------------------------
# ENV VARS REQUIRED:
#   APP_GATEWAY_NAME
#   AZ_RESOURCE_GROUP
#
# OPTIONAL:
#   METRIC_TIME_RANGE  (default: PT1H)
#
# This script:
#  1) Gets the Application Gateway resource ID
#  2) For each metric, runs a single 'az monitor metrics list' 
#     with the aggregator from METRIC_TO_AGGREGATOR
#  3) Parses the result (or stores 0 on error)
#  4) Adds threshold-based checks and produces a JSON: { "metrics": { ... }, "issues": [...] }
# -----------------------------------------------------------------------------

: "${APP_GATEWAY_NAME:?Must set APP_GATEWAY_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

METRIC_TIME_RANGE="${METRIC_TIME_RANGE:-PT1H}"
OUTPUT_FILE="app_gateway_metrics.json"

echo "Fetching metrics for Application Gateway \`$APP_GATEWAY_NAME\` in resource group \`$AZ_RESOURCE_GROUP\` over $METRIC_TIME_RANGE..."

# 1) Get the resource ID
AGW_RESOURCE_ID=$(az network application-gateway show \
  --name "$APP_GATEWAY_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "id" -o tsv 2>/dev/null || true)

if [[ -z "$AGW_RESOURCE_ID" ]]; then
  echo "ERROR: Could not find Application Gateway \`$APP_GATEWAY_NAME\` in \`$AZ_RESOURCE_GROUP\`."
  exit 1
fi

echo "Using resource ID: $AGW_RESOURCE_ID"

metrics_json='{}'
issues_json='{"issues": []}'

# -----------------------------------------------------------------------------
# Helper function to parse aggregator results
# -----------------------------------------------------------------------------
parse_metric_value() {
  local raw_json="$1"
  local aggregator="$2"

  # Check JSON validity
  if ! echo "$raw_json" | jq '.' >/dev/null 2>&1; then
    echo "0"
    return
  fi

  # Check if .value has data
  local val_len
  val_len=$(echo "$raw_json" | jq '.value | length')
  if [[ "$val_len" == "0" || "$val_len" == "null" ]]; then
    echo "0"
    return
  fi

  # Parse based on aggregator
  case "$aggregator" in
    "Sum")
      echo "$raw_json" | jq '[.value[].timeseries[].data[].sum // 0] | add' || echo "0"
      ;;
    "Count")
      echo "$raw_json" | jq '[.value[].timeseries[].data[].count // 0] | add' || echo "0"
      ;;
    "Average")
      echo "$raw_json" | jq '
        .value[].timeseries[].data[] | (.average // 0)
      ' | awk '{ sum+=$1; cnt++ } END { if(cnt>0){printf "%.2f", sum/cnt} else{print 0} }'
      ;;
    "Max")
      echo "$raw_json" | jq '[.value[].timeseries[].data[].max // 0] | max' || echo "0"
      ;;
    "Min")
      echo "$raw_json" | jq '[.value[].timeseries[].data[].min // 0] | min' || echo "0"
      ;;
    *)
      echo "0"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# 2) Loop over METRICS_TO_FETCH
# -----------------------------------------------------------------------------
for metric_name in "${METRICS_TO_FETCH[@]}"; do
  aggregator="${METRIC_TO_AGGREGATOR[$metric_name]:-}"

  if [[ -z "$aggregator" ]]; then
    echo "No aggregator defined for \`$metric_name\`. Storing 0."
    metrics_json=$(echo "$metrics_json" | jq \
      --arg m "$metric_name" --argjson val 0 \
      '. + {($m): $val}')
    continue
  fi

  cmd="az monitor metrics list \
    --resource \"$AGW_RESOURCE_ID\" \
    --metric \"$metric_name\" \
    --interval \"$METRIC_TIME_RANGE\" \
    --aggregation \"$aggregator\" \
    -o json"

  echo "Querying metric \`$metric_name\` with aggregator \`$aggregator\`..."
  echo "Command: $cmd"

  # Capture stdout in cli_stdout, stderr in app_gw_metrics_errors.log
  if ! cli_stdout=$(eval "$cmd" 2>app_gw_metrics_errors.log); then
    echo "ERROR: aggregator=$aggregator for metric=$metric_name"
    cat app_gw_metrics_errors.log
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Failed to Fetch Metric \`$metric_name\` for Application Gateway \`$APP_GATEWAY_NAME\`" \
      --arg details "$(cat app_gw_metrics_errors.log)" \
      --arg severity "4" \
      --arg nextStep "Check aggregator or permissions. Possibly not supported in your tier/region." \
      '.issues += [{
         "title": $title,
         "details": $details,
         "next_step": $nextStep,
         "severity": ($severity | tonumber)
       }]')
    metrics_json=$(echo "$metrics_json" | jq \
      --arg m "$metric_name" --argjson val 0 \
      '. + {($m): $val}')
    rm -f app_gw_metrics_errors.log
    continue
  fi
  rm -f app_gw_metrics_errors.log

  # echo "Raw CLI output for \`$metric_name\`, aggregator=\`$aggregator\`:"
  # echo "$cli_stdout"

  # Parse metric value
  raw_val=$(parse_metric_value "$cli_stdout" "$aggregator")

  # Trim whitespace/newlines
  val="$(echo "$raw_val" | xargs)"

  # If empty, default to "0"
  if [[ -z "$val" ]]; then
    val="0"
  fi

  echo "Value for \`$metric_name\`: $val"

  # If $val is numeric => --argjson, else store as string
  if [[ "$val" =~ ^-?[0-9]*\.?[0-9]+$ ]]; then
    metrics_json=$(echo "$metrics_json" | jq \
      --arg m "$metric_name" \
      --argjson v "$val" \
      '. + {($m): $v}')
  else
    metrics_json=$(echo "$metrics_json" | jq \
      --arg m "$metric_name" \
      --arg v "$val" \
      '. + {($m): $v}')
  fi
done

# -----------------------------------------------------------------------------
# 3) Threshold / Issue Checks for the new metrics
# -----------------------------------------------------------------------------
unhealthy=$(echo "$metrics_json" | jq '.UnhealthyHostCount // 0')
if (( $(echo "$unhealthy > 0" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Detected Unhealthy Hosts in Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "UnhealthyHostCount = $unhealthy" \
    --arg severity "2" \
    --arg nextStep "Check backend pool health for App Gateway  \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`" \
    '.issues += [{
      "title": $title,
      "details": $details,
      "next_step": $nextStep,
      "severity": ($severity | tonumber)
    }]')
fi

total_requests=$(echo "$metrics_json" | jq '.TotalRequests // 0')
failed_requests=$(echo "$metrics_json" | jq '.FailedRequests // 0')

# If we have some traffic, check the failure rate
if (( $(echo "$total_requests > 0" | bc -l) )); then
  fail_rate=$(awk "BEGIN { printf \"%.2f\", $failed_requests/$total_requests * 100 }")
  if (( $(echo "$fail_rate >= 10.0" | bc -l) )); then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "High Failure Rate for Application Gateway \`$APP_GATEWAY_NAME\`" \
      --arg details "Failure rate is $fail_rate%, above 10% threshold." \
      --arg severity "2" \
      --arg nextStep "Investigate 4xx/5xx responses or check logs for App Gateway  \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`" \
      '.issues += [{
         "title": $title,
         "details": $details,
         "next_step": $nextStep,
         "severity": ($severity | tonumber)
       }]')
  fi
fi

current_conn=$(echo "$metrics_json" | jq '.CurrentConnections // 0')
# Suppose we consider > 500 average connections as high usage
if (( $(echo "$current_conn > 500" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High Current Connections for Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "Avg CurrentConnections = $current_conn is above 500." \
    --arg severity "2" \
    --arg nextStep "Check if autoscaling is configured and verify capacity for App Gateway  \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`" \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
    }]')
fi

throughput=$(echo "$metrics_json" | jq '.Throughput // 0')
# If throughput is above e.g. 1 MB/s = 1,000,000 bytes/s average => threshold
if (( $(echo "$throughput > 1000000" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High Throughput for Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "Throughput = $throughput bytes/s is above 1 MB/s." \
    --arg severity "2" \
    --arg nextStep "Confirm App Gateway scaling, check backend performance." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
    }]')
fi

client_rtt=$(echo "$metrics_json" | jq '.ClientRtt // 0')
# e.g. consider above 300 ms average to be quite high
if (( $(echo "$client_rtt > 300" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High Client Round Trip Time for Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "Avg ClientRtt = $client_rtt ms indicates significant latency." \
    --arg severity "2" \
    --arg nextStep "Investigate client-side latency or network paths. Possibly check CDN or caching." \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
    }]')
fi

backend_connect_time=$(echo "$metrics_json" | jq '.BackendConnectTime // 0')
# e.g. if backend connect time > 200ms => indicates slow handshake or networking issues
if (( $(echo "$backend_connect_time > 200" | bc -l) )); then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "High Backend Connect Time for Application Gateway \`$APP_GATEWAY_NAME\`" \
    --arg details "Avg BackendConnectTime = $backend_connect_time ms. Possibly slow network or unresponsive backend." \
    --arg severity "2" \
    --arg nextStep "Check backend VNet config, consider enabling keep-alive or investigating network latency for App Gateway  \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\`" \
    '.issues += [{
       "title": $title,
       "details": $details,
       "next_step": $nextStep,
       "severity": ($severity | tonumber)
    }]')
fi

# -----------------------------------------------------------------------------
# 4) Output final JSON
# -----------------------------------------------------------------------------
final_json=$(jq -n \
  --argjson m "$metrics_json" \
  --argjson i "$(echo "$issues_json" | jq '.issues')" \
  '{ "metrics": $m, "issues": $i }'
)

echo "--------------------------------------------------"
echo "Application Gateway Metrics & Issues (Last $METRIC_TIME_RANGE):"
echo "$final_json" | jq .
echo "--------------------------------------------------"
echo "$final_json" > "$OUTPUT_FILE"
echo "Results saved to $OUTPUT_FILE."
