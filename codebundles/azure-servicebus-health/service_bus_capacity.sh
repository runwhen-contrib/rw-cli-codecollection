#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_capacity.sh
#
#  PURPOSE:
#    Analyzes Service Bus namespace capacity and quota utilization
#    to identify potential limits that might be reached
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
# ---------------------------------------------------------------------------

set -euo pipefail

CAPACITY_OUTPUT="service_bus_capacity.json"
ISSUES_OUTPUT="service_bus_capacity_issues.json"
echo "{}" > "$CAPACITY_OUTPUT"
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
# 3) Get namespace details
# ---------------------------------------------------------------------------
echo "Getting details for Service Bus namespace: $SB_NAMESPACE_NAME"

namespace_info=$(az servicebus namespace show \
  --name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json)

# Extract SKU and capacity information
sku=$(echo "$namespace_info" | jq -r '.sku.name')
capacity=$(echo "$namespace_info" | jq -r '.sku.capacity // 1')
echo "Service Bus SKU: $sku, Capacity: $capacity"

# Get resource ID for metrics
resource_id=$(echo "$namespace_info" | jq -r '.id')

# ---------------------------------------------------------------------------
# 4) Get entity counts
# ---------------------------------------------------------------------------
echo "Retrieving entity counts for Service Bus namespace: $SB_NAMESPACE_NAME"

# Get queue count
queues=$(az servicebus queue list \
  --namespace-name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json)
queue_count=$(echo "$queues" | jq 'length')
echo "Queue count: $queue_count"

# Get topic count
topics=$(az servicebus topic list \
  --namespace-name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json)
topic_count=$(echo "$topics" | jq 'length')
echo "Topic count: $topic_count"

# Get subscription count
subscription_count=0
if [[ "$topic_count" -gt 0 ]]; then
  for topic in $(echo "$topics" | jq -r '.[].name'); do
    subs=$(az servicebus topic subscription list \
      --namespace-name "$SB_NAMESPACE_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --topic-name "$topic" \
      -o json)
    sub_count=$(echo "$subs" | jq 'length')
    subscription_count=$((subscription_count + sub_count))
  done
fi
echo "Subscription count: $subscription_count"

# ---------------------------------------------------------------------------
# 5) Get current throughput metrics
# ---------------------------------------------------------------------------
echo "Retrieving throughput metrics for Service Bus namespace: $SB_NAMESPACE_NAME"

# Get current throughput metrics
throughput_metrics=$(az monitor metrics list \
  --resource "$resource_id" \
  --metric "IncomingMessages,OutgoingMessages,ThrottledRequests" \
  --interval PT1H \
  --aggregation Total \
  -o json)

# Extract maximum values
incoming_max=$(echo "$throughput_metrics" | jq '.value[] | select(.name.value == "IncomingMessages") | .timeseries[0].data | map(.total) | max // 0')
outgoing_max=$(echo "$throughput_metrics" | jq '.value[] | select(.name.value == "OutgoingMessages") | .timeseries[0].data | map(.total) | max // 0')
throttled_max=$(echo "$throughput_metrics" | jq '.value[] | select(.name.value == "ThrottledRequests") | .timeseries[0].data | map(.total) | max // 0')

echo "Max incoming messages (last hour): $incoming_max"
echo "Max outgoing messages (last hour): $outgoing_max"
echo "Max throttled requests (last hour): $throttled_max"

# ---------------------------------------------------------------------------
# 6) Calculate quota limits based on SKU
# ---------------------------------------------------------------------------
echo "Calculating quota limits for $sku SKU..."

# Define limits based on SKU
case "$sku" in
  "Basic")
    max_queues=1000
    max_topics=1000
    max_subscriptions=2000
    max_namespace_size=1  # GB
    max_message_size=256  # KB
    max_throughput_units=1
    max_brokered_connections=100
    ;;
  "Standard")
    max_queues=10000
    max_topics=10000
    max_subscriptions=20000
    max_namespace_size=5  # GB
    max_message_size=256  # KB
    max_throughput_units=$capacity
    max_brokered_connections=$((1000 * capacity))
    ;;
  "Premium")
    max_queues=10000
    max_topics=10000
    max_subscriptions=20000
    max_namespace_size=$((5 * capacity))  # GB
    max_message_size=1024  # KB
    max_throughput_units=$capacity
    max_brokered_connections=$((2000 * capacity))
    ;;
  *)
    max_queues=0
    max_topics=0
    max_subscriptions=0
    max_namespace_size=0
    max_message_size=0
    max_throughput_units=0
    max_brokered_connections=0
    echo "Unknown SKU: $sku"
    ;;
esac

# Get current namespace size
size_metrics=$(az monitor metrics list \
  --resource "$resource_id" \
  --metric "Size" \
  --interval PT1H \
  --aggregation Average \
  -o json)
current_size_bytes=$(echo "$size_metrics" | jq '.value[0].timeseries[0].data | map(.average) | max // 0')
current_size_gb=$(echo "scale=2; $current_size_bytes / 1024 / 1024 / 1024" | bc)
current_size_percent=$(echo "scale=2; $current_size_gb * 100 / $max_namespace_size" | bc)

echo "Current namespace size: $current_size_gb GB of $max_namespace_size GB (${current_size_percent}%)"

# Get current connection count
connection_metrics=$(az monitor metrics list \
  --resource "$resource_id" \
  --metric "ActiveConnections" \
  --interval PT1H \
  --aggregation Maximum \
  -o json)
current_connections=$(echo "$connection_metrics" | jq '.value[0].timeseries[0].data | map(.maximum) | max // 0')
connections_percent=$(echo "scale=2; $current_connections * 100 / $max_brokered_connections" | bc)

echo "Current connections: $current_connections of $max_brokered_connections (${connections_percent}%)"

# ---------------------------------------------------------------------------
# 7) Combine capacity data
# ---------------------------------------------------------------------------
capacity_data=$(jq -n \
  --arg sku "$sku" \
  --arg capacity "$capacity" \
  --argjson queue_count "$queue_count" \
  --argjson topic_count "$topic_count" \
  --argjson subscription_count "$subscription_count" \
  --argjson max_queues "$max_queues" \
  --argjson max_topics "$max_topics" \
  --argjson max_subscriptions "$max_subscriptions" \
  --argjson max_namespace_size "$max_namespace_size" \
  --argjson max_message_size "$max_message_size" \
  --argjson max_throughput_units "$max_throughput_units" \
  --argjson max_brokered_connections "$max_brokered_connections" \
  --argjson current_size_percent "$current_size_percent" \
  --argjson current_size_gb "$current_size_gb" \
  --argjson current_connections "$current_connections" \
  --argjson connections_percent "$connections_percent" \
  --argjson incoming_max "$incoming_max" \
  --argjson outgoing_max "$outgoing_max" \
  --argjson throttled_max "$throttled_max" \
  '{
    sku: $sku,
    capacity_units: $capacity,
    entities: {
      queue_count: $queue_count,
      topic_count: $topic_count,
      subscription_count: $subscription_count,
      queue_percent: ($queue_count * 100 / $max_queues),
      topic_percent: ($topic_count * 100 / $max_topics),
      subscription_percent: ($subscription_count * 100 / $max_subscriptions)
    },
    size: {
      current_percent: $current_size_percent,
      current_gb: $current_size_gb,
      max_gb: $max_namespace_size
    },
    connections: {
      current: $current_connections,
      percent: $connections_percent,
      max: $max_brokered_connections
    },
    throughput: {
      incoming_max: $incoming_max,
      outgoing_max: $outgoing_max,
      throttled_max: $throttled_max,
      max_throughput_units: $max_throughput_units
    },
    limits: {
      max_queues: $max_queues,
      max_topics: $max_topics,
      max_subscriptions: $max_subscriptions,
      max_namespace_size: $max_namespace_size,
      max_message_size: $max_message_size,
      max_throughput_units: $max_throughput_units,
      max_brokered_connections: $max_brokered_connections
    }
  }')

echo "$capacity_data" > "$CAPACITY_OUTPUT"
echo "Capacity data saved to $CAPACITY_OUTPUT"

# ---------------------------------------------------------------------------
# 8) Analyze capacity data for issues
# ---------------------------------------------------------------------------
echo "Analyzing capacity data for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check namespace size
size_percent=$(jq '.size.current_percent' <<< "$capacity_data")
if (( $(echo "$size_percent > ${SIZE_PERCENTAGE_THRESHOLD:-80}" | bc -l) )); then
  current_gb=$(jq '.size.current_gb' <<< "$capacity_data")
  max_gb=$(jq '.size.max_gb' <<< "$capacity_data")
  queue_count=$(jq '.entities.queue_count' <<< "$capacity_data")
  topic_count=$(jq '.entities.topic_count' <<< "$capacity_data")
  subscription_count=$(jq '.entities.subscription_count' <<< "$capacity_data")
  
  add_issue 3 \
    "Service Bus namespace \`$SB_NAMESPACE_NAME\` is approaching size limit (${size_percent}%)" \
    "Consider implementing message cleanup strategies or upgrading SKU/capacity" \
    "NAMESPACE CAPACITY ANALYSIS:
- Current Usage: ${current_gb} GB of ${max_gb} GB (${size_percent}%)
- Namespace: $SB_NAMESPACE_NAME
- SKU: $sku
- Capacity Units: $capacity
- Queue Count: $queue_count
- Topic Count: $topic_count  
- Subscription Count: $subscription_count

CONTEXT: High namespace storage utilization indicates significant message accumulation across queues and topics. At ${SIZE_PERCENTAGE_THRESHOLD:-80}%+ capacity, you're approaching the hard limit where new messages may be rejected. This typically occurs due to:
1. Message backlog from slow or failed consumers
2. Large message sizes consuming storage quickly
3. Long message TTL values preventing automatic cleanup
4. Dead letter queues accumulating failed messages
5. Insufficient consumer throughput relative to producer rates

INVESTIGATION STEPS:
1. Identify largest queues/topics: Review individual entity sizes
2. Check for message backlogs in active queues and subscriptions
3. Review dead letter queues for accumulated failed messages
4. Analyze message TTL settings across entities
5. Monitor producer vs consumer rates to identify imbalances
6. Review auto-delete policies on idle entities

RECOMMENDATIONS:
- Implement message cleanup strategies (shorter TTL, auto-delete policies)
- Scale consumer applications to process backlogs faster
- Consider upgrading to higher SKU tier or increasing capacity units
- Implement monitoring and alerting for storage utilization
- Review and optimize message sizes if possible
- Clean up dead letter queues after investigation

BUSINESS IMPACT: Reaching storage limits will cause message publishing failures, potentially disrupting critical business operations and causing data loss."
fi

# Check for throttling
throttled_max=$(jq '.throughput.throttled_max' <<< "$capacity_data")
if (( $(echo "$throttled_max > 0" | bc -l) )); then
  add_issue 3 \
    "Service Bus namespace \`$SB_NAMESPACE_NAME\` is experiencing throttling" \
    "Consider increasing capacity units or optimizing message processing" \
    "Throttled requests detected: $throttled_max"
fi

# Check entity quotas
queue_percent=$(jq '.entities.queue_percent' <<< "$capacity_data")
if (( $(echo "$queue_percent > ${SIZE_PERCENTAGE_THRESHOLD:-80}" | bc -l) )); then
  add_issue 3 \
    "Service Bus namespace \`$SB_NAMESPACE_NAME\` is approaching queue quota (${queue_percent}%)" \
    "Review queue usage and consider consolidating or upgrading if needed" \
    "Current queues: $(jq '.entities.queue_count' <<< "$capacity_data") of $(jq '.limits.max_queues' <<< "$capacity_data")"
fi

topic_percent=$(jq '.entities.topic_percent' <<< "$capacity_data")
if (( $(echo "$topic_percent > ${SIZE_PERCENTAGE_THRESHOLD:-80}" | bc -l) )); then
  add_issue 3 \
    "Service Bus namespace \`$SB_NAMESPACE_NAME\` is approaching topic quota (${topic_percent}%)" \
    "Review topic usage and consider consolidating or upgrading if needed" \
    "Current topics: $(jq '.entities.topic_count' <<< "$capacity_data") of $(jq '.limits.max_topics' <<< "$capacity_data")"
fi

subscription_percent=$(jq '.entities.subscription_percent' <<< "$capacity_data")
if (( $(echo "$subscription_percent > ${SIZE_PERCENTAGE_THRESHOLD:-80}" | bc -l) )); then
  add_issue 3 \
    "Service Bus namespace \`$SB_NAMESPACE_NAME\` is approaching subscription quota (${subscription_percent}%)" \
    "Review subscription usage and consider consolidating or upgrading if needed" \
    "Current subscriptions: $(jq '.entities.subscription_count' <<< "$capacity_data") of $(jq '.limits.max_subscriptions' <<< "$capacity_data")"
fi

# Check connection usage
connections_percent=$(jq '.connections.percent' <<< "$capacity_data")
if (( $(echo "$connections_percent > ${SIZE_PERCENTAGE_THRESHOLD:-80}" | bc -l) )); then
  add_issue 3 \
    "Service Bus namespace \`$SB_NAMESPACE_NAME\` is approaching connection limit (${connections_percent}%)" \
    "Review connection usage patterns and consider upgrading capacity if needed" \
    "Current connections: $(jq '.connections.current' <<< "$capacity_data") of $(jq '.connections.max' <<< "$capacity_data")"
fi

# Check if Basic tier but has significant usage
sku=$(jq -r '.sku' <<< "$capacity_data")
if [[ "$sku" == "Basic" && $(echo "$size_percent > 50" | bc -l) -eq 1 ]]; then
  add_issue 3 \
    "Service Bus namespace \`$SB_NAMESPACE_NAME\` is using Basic tier with significant usage" \
    "Consider upgrading to Standard or Premium tier for better features and quota" \
    "Basic tier has limited message size, throughput, and no topics/subscriptions or partitioning"
fi

# Check if Standard tier but approaching limits
if [[ "$sku" == "Standard" && $(echo "$size_percent > 70" | bc -l) -eq 1 ]]; then
  capacity_units=$(jq '.capacity_units' <<< "$capacity_data")
  max_capacity=20
  
  if [[ "$capacity_units" -lt "$max_capacity" ]]; then
    add_issue 3 \
      "Service Bus namespace \`$SB_NAMESPACE_NAME\` could benefit from increased capacity units" \
      "Consider increasing capacity units from $capacity_units to improve throughput" \
      "Standard tier supports up to $max_capacity capacity units"
  fi
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 