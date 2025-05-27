#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_metrics.sh
#
#  PURPOSE:
#    Retrieves metrics for a Service Bus namespace and analyzes for potential issues
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
#    METRIC_INTERVAL                 Time interval for metrics in ISO 8601 format (default: PT1H)
# ---------------------------------------------------------------------------

set -euo pipefail

METRICS_OUTPUT="service_bus_metrics.json"
ISSUES_OUTPUT="service_bus_metrics_issues.json"
METRIC_INTERVAL="${METRIC_INTERVAL:-PT1H}"
echo "{}" > "$METRICS_OUTPUT"
echo '{"issues":[]}' > "$ISSUES_OUTPUT"

# ---------------------------------------------------------------------------
# 1) Determine subscription ID
# ---------------------------------------------------------------------------
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
  subscription=$(az account show --query "id" -o tsv)
  echo "Using current Azure CLI subscription: $subscription"
else
  subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
  echo "Using AZURE_RESOURCE_SUBSCRIPTION_ID: $subscription"
fi

az account set --subscription "$subscription"

# ---------------------------------------------------------------------------
# 2) Validate required env vars
# ---------------------------------------------------------------------------
: "${SB_NAMESPACE_NAME:?Must set SB_NAMESPACE_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

# ---------------------------------------------------------------------------
# 3) Query important Service Bus metrics
# ---------------------------------------------------------------------------
echo "Retrieving metrics for Service Bus namespace: $SB_NAMESPACE_NAME"

resource_id=$(az servicebus namespace show \
  --name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "id" -o tsv)

# Get key metrics for namespace
metrics_list=(
  "ServerErrors" 
  "ThrottledRequests"
  "UserErrors"
  "ActiveConnections"
  "IncomingMessages"
  "OutgoingMessages"
  "Size"
)

metrics_data="{}"

for metric in "${metrics_list[@]}"; do
  echo "Fetching metric: $metric"
  
  result=$(az monitor metrics list \
    --resource "$resource_id" \
    --metric "$metric" \
    --interval "$METRIC_INTERVAL" \
    --aggregation "Total" "Average" "Maximum" \
    --output json)
  
  metrics_data=$(echo "$metrics_data" | jq --arg m "$metric" --argjson data "$result" \
    '. + {($m): $data}')
done

echo "$metrics_data" > "$METRICS_OUTPUT"
echo "Metrics data saved to $METRICS_OUTPUT"

# ---------------------------------------------------------------------------
# 4) Analyze metrics for issues
# ---------------------------------------------------------------------------
echo "Analyzing metrics for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check for server errors
server_errors=$(jq -r '.ServerErrors.value[0].timeseries[0].data | map(select(.total > 0)) | length' <<< "$metrics_data")
if [[ "$server_errors" -gt 0 ]]; then
  add_issue 1 \
    "Service Bus namespace $SB_NAMESPACE_NAME has server errors" \
    "Investigate service bus logs for the specific errors and consider opening a support case with Microsoft" \
    "Server errors detected in metrics"
fi

# Check for throttling
throttled=$(jq -r '.ThrottledRequests.value[0].timeseries[0].data | map(select(.total > 0)) | length' <<< "$metrics_data")
if [[ "$throttled" -gt 0 ]]; then
  add_issue 2 \
    "Service Bus namespace $SB_NAMESPACE_NAME is experiencing throttling" \
    "Consider upgrading the SKU or scaling up capacity units if this is a persistent issue" \
    "Throttling detected in metrics"
fi

# Check for high user errors
user_errors=$(jq -r '.UserErrors.value[0].timeseries[0].data | map(select(.total > 10)) | length' <<< "$metrics_data")
if [[ "$user_errors" -gt 0 ]]; then
  add_issue 2 \
    "Service Bus namespace $SB_NAMESPACE_NAME has a high number of user errors" \
    "Review application logs and SAS key policies to ensure proper authentication and permissions" \
    "High user error count detected in metrics"
fi

# Check for namespace size usage
size_percent=$(jq -r '.Size.value[0].timeseries[0].data | map(.maximum) | max // 0' <<< "$metrics_data")
if (( $(echo "$size_percent > 80" | bc -l) )); then
  add_issue 2 \
    "Service Bus namespace $SB_NAMESPACE_NAME is approaching storage limit (${size_percent}%)" \
    "Consider implementing a message purging strategy or increasing the namespace size limit" \
    "Storage usage exceeding 80%"
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 