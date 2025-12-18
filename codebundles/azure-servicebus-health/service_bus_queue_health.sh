#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_queue_health.sh
#
#  PURPOSE:
#    Retrieves information about Service Bus queues and checks for health issues
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
# ---------------------------------------------------------------------------

set -euo pipefail

QUEUES_OUTPUT="service_bus_queues.json"
ISSUES_OUTPUT="service_bus_queue_issues.json"
echo "[]" > "$QUEUES_OUTPUT"
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
# 3) Get all queues in the namespace
# ---------------------------------------------------------------------------
echo "Retrieving queues for Service Bus namespace: $SB_NAMESPACE_NAME"

queues=$(az servicebus queue list \
  --namespace-name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json)

echo "$queues" > "$QUEUES_OUTPUT"
echo "Queues data saved to $QUEUES_OUTPUT"

# Count the queues
queue_count=$(jq '. | length' <<< "$queues")
echo "Found $queue_count queues in namespace $SB_NAMESPACE_NAME"

# ---------------------------------------------------------------------------
# 4) Analyze queues for issues
# ---------------------------------------------------------------------------
echo "Analyzing queues for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4" observed_at="${5:-$(date '+%Y-%m-%d %H:%M:%S')}"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              --arg o "$observed_at" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d,observed_at:$o}]' \
              <<<"$issues")
}

# Check for disabled queues
disabled_queues=$(jq -r '[.[] | select(.status == "Disabled") | .name] | join(", ")' <<< "$queues")
disabled_at=$(jq -r '[.[] | select(.status == "Disabled") | .updatedAt] | join(", ")' <<< "$queues")
if [[ -n "$disabled_queues" ]]; then
  disabled_count=$(jq -r '[.[] | select(.status == "Disabled")] | length' <<< "$queues")
  add_issue 3 \
    "Service Bus namespace $SB_NAMESPACE_NAME has $disabled_count disabled queue(s): $disabled_queues" \
    "Investigate why these queues are disabled and enable them if needed" \
    "DISABLED QUEUE ANALYSIS:
- Disabled Queue(s): $disabled_queues
- Count: $disabled_count
- Last Updated: $disabled_at
- Namespace: $SB_NAMESPACE_NAME
- Resource Group: $AZ_RESOURCE_GROUP

CONTEXT: Disabled queues cannot send or receive messages, which disrupts message flow and can cause application failures. Queues may be disabled:
1. Manually by administrators during maintenance
2. Automatically by Azure due to policy violations
3. As a result of subscription or namespace suspension
4. Due to quota exhaustions or security concerns

INVESTIGATION STEPS:
1. Check Azure portal for queue status and any warning messages
2. Review Azure Activity Log for who disabled the queue and when
3. Verify no ongoing maintenance or security incidents
4. Check for any namespace-level issues affecting multiple queues
5. Review application logs for errors around the disabled time ($disabled_at)
6. Verify queue configuration and policies are correct

RECOMMENDATIONS:
- Re-enable queues if disabled unintentionally
- Document maintenance windows if intentionally disabled
- Implement monitoring alerts for queue status changes
- Review access control to prevent unauthorized modifications
- Verify applications have proper error handling for disabled queues

BUSINESS IMPACT: Disabled queues cause message delivery failures, application errors, and disrupted business workflows requiring immediate attention."  \
    "$disabled_at"
fi

# Check for dead-letter messages
for queue_name in $(jq -r '.[].name' <<< "$queues"); do
  echo "Checking queue: $queue_name"
  
  # Get message count
  queue_details=$(az servicebus queue show \
    --namespace-name "$SB_NAMESPACE_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --name "$queue_name" \
    -o json)
  
  # Check dead letter count
  dead_letter_count=$(jq -r '.countDetails.deadLetterMessageCount // 0' <<< "$queue_details")
  # Ensure dead_letter_count is a valid number
  if ! [[ "$dead_letter_count" =~ ^[0-9]+$ ]]; then
    dead_letter_count=0
  fi
  if [[ "$dead_letter_count" -gt "${DEAD_LETTER_THRESHOLD:-100}" ]]; then
    # Determine severity based on count magnitude
    if [[ "$dead_letter_count" -gt 10000 ]]; then
      severity=2
      urgency="CRITICAL"
    elif [[ "$dead_letter_count" -gt 1000 ]]; then
      severity=3
      urgency="HIGH"
    else
      severity=3
      urgency="MODERATE"
    fi
    
    # Get additional context for LLM analysis
    max_delivery_count=$(jq -r '.maxDeliveryCount' <<< "$queue_details")
    queue_status=$(jq -r '.status' <<< "$queue_details")
    auto_delete_idle=$(jq -r '.autoDeleteOnIdle' <<< "$queue_details")
    ttl=$(jq -r '.defaultMessageTimeToLive' <<< "$queue_details")
    lock_duration=$(jq -r '.lockDuration' <<< "$queue_details")
    
    add_issue $severity \
      "Queue \`$queue_name\` has $dead_letter_count dead-lettered messages" \
      "Investigate dead-lettered messages using Azure portal or CLI. Check for processing errors, message format issues, or consumer failures" \
      "QUEUE DEAD LETTER ANALYSIS:
- Message Count: $dead_letter_count dead-lettered messages
- Severity Level: $urgency ($severity)
- Queue Name: $queue_name
- Queue Status: $queue_status
- Max Delivery Count: $max_delivery_count
- Lock Duration: $lock_duration
- Auto Delete on Idle: $auto_delete_idle
- Default Message TTL: $ttl

CONTEXT: Dead-lettered messages in queues indicate systematic processing failures. Messages are moved to the dead letter queue when they exceed the maximum delivery count ($max_delivery_count), expire, or encounter processing errors. This suggests:
1. Consumer application errors or crashes during message processing
2. Message format/content issues that cause processing failures
3. Lock timeout issues where messages aren't processed within lock duration ($lock_duration)
4. Infrastructure problems preventing message delivery
5. Poison messages that consistently fail processing

INVESTIGATION STEPS:
1. Access dead letter queue via Azure portal or CLI: az servicebus queue show --name '$queue_name/\$DeadLetterQueue'
2. Sample recent dead-lettered messages to identify error patterns
3. Review DeadLetterReason and DeadLetterErrorDescription properties
4. Check consumer application logs for processing errors and exceptions
5. Verify message format matches expected schema
6. Analyze lock duration vs processing time requirements
7. Review max delivery count ($max_delivery_count) appropriateness

RECOMMENDATIONS:
- Implement dead letter message reprocessing logic if appropriate
- Adjust lock duration if messages are timing out during processing
- Review and optimize message processing logic
- Consider implementing circuit breaker patterns for resilience
- Set up monitoring for dead letter queue depth

BUSINESS IMPACT: Failed message processing may result in data loss, delayed operations, incomplete business workflows, and potential compliance issues."
  fi
  
  # Check for large active message count
  active_count=$(jq -r '.countDetails.activeMessageCount // 0' <<< "$queue_details")
  # Ensure active_count is a valid number
  if ! [[ "$active_count" =~ ^[0-9]+$ ]]; then
    active_count=0
  fi
  if [[ "$active_count" -gt "${ACTIVE_MESSAGE_THRESHOLD:-1000}" ]]; then
    # Get additional context for backlog analysis
    scheduled_count=$(jq -r '.countDetails.scheduledMessageCount // 0' <<< "$queue_details")
    transfer_dead_letter_count=$(jq -r '.countDetails.transferDeadLetterMessageCount // 0' <<< "$queue_details")
    transfer_count=$(jq -r '.countDetails.transferMessageCount // 0' <<< "$queue_details")
    queue_status=$(jq -r '.status' <<< "$queue_details")
    max_delivery_count=$(jq -r '.maxDeliveryCount' <<< "$queue_details")
    lock_duration=$(jq -r '.lockDuration' <<< "$queue_details")
    
    # Ensure all counts are valid numbers
    if ! [[ "$scheduled_count" =~ ^[0-9]+$ ]]; then scheduled_count=0; fi
    if ! [[ "$transfer_dead_letter_count" =~ ^[0-9]+$ ]]; then transfer_dead_letter_count=0; fi
    if ! [[ "$transfer_count" =~ ^[0-9]+$ ]]; then transfer_count=0; fi
    
    add_issue 3 \
      "Queue $queue_name has $active_count active messages" \
      "Verify consumers are processing messages at an adequate rate" \
      "MESSAGE BACKLOG ANALYSIS:
- Active Messages: $active_count (exceeds threshold of ${ACTIVE_MESSAGE_THRESHOLD:-1000})
- Scheduled Messages: $scheduled_count
- Transfer Messages: $transfer_count
- Transfer Dead Letter Messages: $transfer_dead_letter_count
- Queue Name: $queue_name
- Queue Status: $queue_status
- Max Delivery Count: $max_delivery_count
- Lock Duration: $lock_duration

CONTEXT: Large active message counts indicate a processing backlog where messages are arriving faster than they can be consumed. This suggests:
1. Consumer throughput is insufficient for current message volume
2. Consumer applications may be down or experiencing performance issues
3. Message processing logic may be too slow or resource-intensive
4. Scaling issues with consumer infrastructure
5. Lock timeout issues preventing efficient message processing

INVESTIGATION STEPS:
1. Check consumer application health and availability
2. Monitor consumer processing rates and performance metrics
3. Verify consumer scaling configuration (auto-scaling, instance counts)
4. Analyze message processing duration and identify bottlenecks
5. Review consumer resource utilization (CPU, memory, network)
6. Check for any consumer application errors or exceptions in logs
7. Verify lock duration ($lock_duration) is appropriate for processing time
8. Check if max delivery count ($max_delivery_count) is being reached frequently

RECOMMENDATIONS:
- Scale out consumer instances if processing is CPU/memory bound
- Optimize message processing logic for better throughput
- Implement consumer health monitoring and alerting
- Consider message batching if supported by your application
- Review queue configuration (prefetch count, session handling)
- Adjust lock duration if messages are timing out during processing
- Implement circuit breaker patterns for resilience

BUSINESS IMPACT: Message processing delays can lead to degraded user experience, delayed business operations, and potential SLA violations."
  fi
  
  # Check if queue is close to max size
  max_size_bytes=$(jq -r '.maxSizeInMegabytes' <<< "$queue_details")
  max_size_bytes=$((max_size_bytes * 1024 * 1024))
  size_bytes=$(jq -r '.sizeInBytes' <<< "$queue_details")
  size_percent=$(( (size_bytes * 100) / max_size_bytes ))
  
  if [[ "$size_percent" -gt "${SIZE_PERCENTAGE_THRESHOLD:-80}" ]]; then
    # Get additional context for size analysis
    max_size_mb=$(jq -r '.maxSizeInMegabytes' <<< "$queue_details")
    message_count=$(jq -r '.countDetails.activeMessageCount // 0' <<< "$queue_details")
    auto_delete_idle=$(jq -r '.autoDeleteOnIdle' <<< "$queue_details")
    enable_partitioning=$(jq -r '.enablePartitioning' <<< "$queue_details")
    
    add_issue 3 \
      "Queue $queue_name is at ${size_percent}% of maximum size" \
      "Consider implementing auto-delete of processed messages or increasing queue size" \
      "QUEUE SIZE CAPACITY ANALYSIS:
- Current Size: $size_bytes bytes (${size_percent}% of capacity)
- Maximum Size: $max_size_mb MB ($max_size_bytes bytes)
- Active Message Count: $message_count
- Queue Name: $queue_name
- Auto Delete on Idle: $auto_delete_idle
- Partitioning Enabled: $enable_partitioning

CONTEXT: Queue approaching storage capacity limit indicates that messages are accumulating faster than they are being consumed or are not being deleted after processing. This can lead to:
1. Queue throttling or message rejection when limit is reached
2. Application failures due to inability to send new messages
3. Increased latency in message processing
4. Potential data loss if messages are rejected
5. Service disruption for message producers

INVESTIGATION STEPS:
1. Verify consumer applications are actively processing and completing messages
2. Check if messages are being explicitly deleted after successful processing
3. Review message retention policies and auto-delete configuration
4. Analyze message size distribution to identify large messages
5. Check if dead-letter messages are contributing to size usage
6. Review historical growth patterns to predict when limit will be reached
7. Verify if partitioning is enabled and functioning correctly

RECOMMENDATIONS:
- Increase queue maximum size if within namespace quota limits
- Implement aggressive message cleanup after successful processing
- Configure auto-delete on idle if appropriate: $auto_delete_idle
- Enable partitioning to increase throughput and capacity (currently: $enable_partitioning)
- Review message TTL settings to automatically expire old messages
- Consider message archival strategy for long-term retention needs
- Scale out consumers to process backlog faster
- Investigate and remove large or unnecessary messages

BUSINESS IMPACT: Reaching queue capacity will cause message rejection, application errors, and potential data loss. Immediate action required to prevent service disruption."
  fi
done

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 