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
  # Get detailed error metrics
  total_errors=$(jq -r '.ServerErrors.value[0].timeseries[0].data | map(.total // 0) | add' <<< "$metrics_data")
  max_errors=$(jq -r '.ServerErrors.value[0].timeseries[0].data | map(.maximum // 0) | max' <<< "$metrics_data")
  avg_errors=$(jq -r '.ServerErrors.value[0].timeseries[0].data | map(.average // 0) | add / length' <<< "$metrics_data")
  
  add_issue 1 \
    "Service Bus namespace $SB_NAMESPACE_NAME has $total_errors server errors" \
    "Investigate service bus logs for the specific errors and consider opening a support case with Microsoft" \
    "SERVER ERROR ANALYSIS:
- Total Server Errors: $total_errors (over $METRIC_INTERVAL interval)
- Maximum Errors in Single Period: $max_errors
- Average Errors: $avg_errors
- Namespace: $SB_NAMESPACE_NAME
- Resource Group: $AZ_RESOURCE_GROUP
- Metric Interval: $METRIC_INTERVAL

CONTEXT: Server errors indicate internal Azure Service Bus issues that are not caused by client applications. These are service-side failures that can impact message reliability and availability. Server errors can result from:
1. Azure infrastructure issues or service degradation
2. Resource exhaustion at the service level
3. Internal Service Bus component failures
4. Transient network or storage issues in Azure backend
5. Service deployment or maintenance activities

INVESTIGATION STEPS:
1. Check Azure Service Health dashboard for any ongoing incidents
2. Review Azure Activity Log for service-level events
3. Query Service Bus diagnostic logs for detailed error information:
   - OperationalLogs for runtime operations
   - RuntimeAuditLogs for audit information
4. Check metrics for correlation with other issues (throttling, connection drops)
5. Verify if errors are transient or persistent
6. Note exact timestamps of errors for Microsoft support investigation
7. Review retry policies in client applications

RECOMMENDATIONS:
- Open Azure support case if errors are persistent (severity 1)
- Implement exponential backoff retry logic in client applications
- Enable diagnostic logging for detailed error tracking
- Set up alerts for server error rate thresholds
- Document error patterns and frequencies for support case
- Consider implementing circuit breaker patterns in applications
- Review namespace health and consider failover strategies if available

BUSINESS IMPACT: Server errors can cause message delivery failures, data loss, and service disruptions. As these are service-side issues, they require Azure support intervention if persistent. Critical severity issue requiring immediate attention."
fi

# Check for throttling
throttled=$(jq -r '.ThrottledRequests.value[0].timeseries[0].data | map(select(.total > 0)) | length' <<< "$metrics_data")
if [[ "$throttled" -gt 0 ]]; then
  # Get detailed throttling metrics
  total_throttled=$(jq -r '.ThrottledRequests.value[0].timeseries[0].data | map(.total // 0) | add' <<< "$metrics_data")
  max_throttled=$(jq -r '.ThrottledRequests.value[0].timeseries[0].data | map(.maximum // 0) | max' <<< "$metrics_data")
  incoming_msgs=$(jq -r '.IncomingMessages.value[0].timeseries[0].data | map(.total // 0) | add' <<< "$metrics_data")
  outgoing_msgs=$(jq -r '.OutgoingMessages.value[0].timeseries[0].data | map(.total // 0) | add' <<< "$metrics_data")
  active_connections=$(jq -r '.ActiveConnections.value[0].timeseries[0].data | map(.maximum // 0) | max' <<< "$metrics_data")
  
  add_issue 3 \
    "Service Bus namespace $SB_NAMESPACE_NAME is experiencing $total_throttled throttled requests" \
    "Consider upgrading the SKU or scaling up capacity units if this is a persistent issue" \
    "THROTTLING ANALYSIS:
- Total Throttled Requests: $total_throttled (over $METRIC_INTERVAL interval)
- Maximum Throttled in Single Period: $max_throttled
- Total Incoming Messages: $incoming_msgs
- Total Outgoing Messages: $outgoing_msgs
- Maximum Active Connections: $active_connections
- Namespace: $SB_NAMESPACE_NAME
- Resource Group: $AZ_RESOURCE_GROUP
- Metric Interval: $METRIC_INTERVAL

CONTEXT: Throttling occurs when the namespace exceeds its allocated throughput limits based on the pricing tier (Basic, Standard, or Premium) and configured throughput units (TU) or messaging units (MU). Azure Service Bus enforces limits on:
1. Operations per second (send, receive, management operations)
2. Number of concurrent connections
3. Message size and throughput (MB/s)
4. CPU usage (Premium tier)

Throttling causes:
- Failed send/receive operations requiring retry
- Increased latency and degraded application performance
- Potential message loss if retry logic is insufficient
- Application errors and timeouts

INVESTIGATION STEPS:
1. Check current namespace pricing tier and capacity allocation
2. Review namespace metrics for specific throttling patterns:
   - High incoming message rate relative to tier limits
   - Connection count approaching tier maximums
   - CPU usage if Premium tier
3. Analyze application request patterns for spikes or sustained high load
4. Verify if throttling coincides with specific business events
5. Check if multiple queues/topics are competing for namespace throughput
6. Review client application retry logic and backoff strategies
7. Verify namespace scaling configuration

RECOMMENDATIONS:
- Upgrade to higher pricing tier (Standard to Premium) for increased throughput
- Scale up by adding throughput units (Standard) or messaging units (Premium)
- Enable auto-scaling if using Premium tier
- Implement efficient connection pooling in client applications
- Use batching for send/receive operations to reduce operation count
- Distribute load across multiple namespaces if possible
- Optimize message size to reduce bandwidth consumption
- Implement proper exponential backoff retry policies
- Consider Premium tier for guaranteed performance and isolation

BUSINESS IMPACT: Throttling causes message delivery delays, application timeouts, and potential data loss. Performance degradation affects user experience and business operations. High priority issue requiring capacity planning review."
fi

# Check for high user errors
user_errors=$(jq -r '.UserErrors.value[0].timeseries[0].data | map(select(.total > 10)) | length' <<< "$metrics_data")
if [[ "$user_errors" -gt 0 ]]; then
  # Get detailed user error metrics
  total_user_errors=$(jq -r '.UserErrors.value[0].timeseries[0].data | map(.total // 0) | add' <<< "$metrics_data")
  max_user_errors=$(jq -r '.UserErrors.value[0].timeseries[0].data | map(.maximum // 0) | max' <<< "$metrics_data")
  avg_user_errors=$(jq -r '.UserErrors.value[0].timeseries[0].data | map(.average // 0) | add / length' <<< "$metrics_data")
  total_requests=$(jq -r '(.IncomingMessages.value[0].timeseries[0].data | map(.total // 0) | add) + (.OutgoingMessages.value[0].timeseries[0].data | map(.total // 0) | add)' <<< "$metrics_data")
  
  add_issue 3 \
    "Service Bus namespace $SB_NAMESPACE_NAME has $total_user_errors user errors" \
    "Review application logs and SAS key policies to ensure proper authentication and permissions" \
    "USER ERROR ANALYSIS:
- Total User Errors: $total_user_errors (over $METRIC_INTERVAL interval)
- Maximum Errors in Single Period: $max_user_errors
- Average Errors: $avg_user_errors
- Total Requests (Incoming + Outgoing): $total_requests
- Error Rate: $(awk "BEGIN {printf \"%.2f%%\", ($total_user_errors / ($total_requests + $total_user_errors)) * 100}")
- Namespace: $SB_NAMESPACE_NAME
- Resource Group: $AZ_RESOURCE_GROUP
- Metric Interval: $METRIC_INTERVAL

CONTEXT: User errors indicate client-side issues with Service Bus operations. These are errors caused by incorrect usage, authentication problems, or authorization failures. Common user error scenarios include:
1. Authentication failures (invalid or expired SAS tokens, connection strings)
2. Authorization errors (insufficient permissions on queues/topics/subscriptions)
3. Invalid operations (operating on non-existent entities)
4. Protocol violations or malformed requests
5. Message size or property limit violations
6. Lock token expiration or invalid lock tokens
7. Message format or encoding issues

INVESTIGATION STEPS:
1. Enable detailed diagnostic logging for the namespace
2. Review application logs for specific error codes and messages
3. Check common Service Bus error codes:
   - 401 Unauthorized: Authentication issues
   - 403 Forbidden: Authorization issues
   - 404 Not Found: Entity doesn't exist
   - 400 Bad Request: Invalid operation or message
4. Verify SAS policies and connection strings are current
5. Check entity names in application code match actual entities
6. Review message content for size/property violations
7. Verify client SDK versions are up to date
8. Check for concurrent operations on same messages (lock conflicts)

RECOMMENDATIONS:
- Implement proper error handling and logging in applications
- Rotate and validate SAS tokens and connection strings
- Review and update access policies (Manage, Send, Listen permissions)
- Add retry logic with exponential backoff for transient errors
- Validate message payloads before sending
- Update client SDKs to latest versions
- Implement connection string validation on application startup
- Set up monitoring for specific error code patterns
- Use Managed Identity authentication to avoid token expiration issues

BUSINESS IMPACT: High user error rates indicate application configuration or code issues that cause operation failures. While not service-level issues, they result in failed message operations, potential data loss, and degraded application functionality requiring developer attention."
fi

# Check for namespace size usage
size_percent=$(jq -r '.Size.value[0].timeseries[0].data | map(.maximum) | max // 0' <<< "$metrics_data")
if (( $(echo "$size_percent > 80" | bc -l) )); then
  # Get additional storage metrics
  avg_size=$(jq -r '.Size.value[0].timeseries[0].data | map(.average // 0) | add / length' <<< "$metrics_data")
  max_size=$(jq -r '.Size.value[0].timeseries[0].data | map(.maximum // 0) | max' <<< "$metrics_data")
  incoming_msgs=$(jq -r '.IncomingMessages.value[0].timeseries[0].data | map(.total // 0) | add' <<< "$metrics_data")
  outgoing_msgs=$(jq -r '.OutgoingMessages.value[0].timeseries[0].data | map(.total // 0) | add' <<< "$metrics_data")
  
  # Calculate message imbalance (use bc for float-safe arithmetic)
  msg_imbalance=$(echo "$incoming_msgs - $outgoing_msgs" | bc -l)
  
  add_issue 3 \
    "Service Bus namespace $SB_NAMESPACE_NAME is approaching storage limit at ${size_percent}%" \
    "Consider implementing a message purging strategy or increasing the namespace size limit" \
    "NAMESPACE STORAGE CAPACITY ANALYSIS:
- Current Storage Usage: ${size_percent}% (maximum observed)
- Average Storage Usage: ${avg_size}%
- Peak Storage Usage: ${max_size}%
- Total Incoming Messages: $incoming_msgs
- Total Outgoing Messages: $outgoing_msgs
- Message Imbalance: $msg_imbalance (incoming - outgoing)
- Namespace: $SB_NAMESPACE_NAME
- Resource Group: $AZ_RESOURCE_GROUP
- Metric Interval: $METRIC_INTERVAL

CONTEXT: Namespace storage capacity limits vary by pricing tier and can be exhausted by accumulated messages, dead-letter messages, and scheduled messages across all queues and topics. Storage limit warnings indicate:
1. Messages accumulating faster than being processed/deleted
2. Large message sizes consuming storage quota
3. Dead-letter queues filling up with unprocessed messages
4. Scheduled messages awaiting delivery
5. Insufficient consumer throughput across multiple entities

When storage limit is reached:
- New messages will be rejected (QUOTA_EXCEEDED errors)
- Publishers will experience send failures
- Applications will fail unless retry logic is implemented
- Service disruption for all queues and topics in namespace

INVESTIGATION STEPS:
1. Identify queues and topics with highest message counts
2. Check dead-letter queues for accumulated failed messages
3. Review message TTL settings across all entities
4. Analyze message sizes and identify large messages
5. Verify consumer applications are running and processing messages
6. Check for inactive or abandoned subscriptions holding messages
7. Review scheduled message counts and delivery times
8. Examine auto-delete on idle configurations
9. Monitor storage growth rate to predict capacity exhaustion time

RECOMMENDATIONS:
- Immediate: Increase namespace storage quota if available for tier
- Scale consumers to process message backlog faster
- Implement aggressive message cleanup after processing
- Configure appropriate message TTL to auto-expire old messages
- Investigate and clear dead-letter queues
- Remove or disable inactive subscriptions
- Enable auto-delete on idle for unused entities
- Consider message archival strategy for long-term retention
- Upgrade to higher pricing tier for increased storage capacity
- Distribute load across multiple namespaces if needed
- Implement monitoring for per-queue/topic storage usage

BUSINESS IMPACT: Storage capacity exhaustion will cause complete service disruption with message rejection and publisher failures across all entities in the namespace. Critical issue requiring immediate action to prevent outage."
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 