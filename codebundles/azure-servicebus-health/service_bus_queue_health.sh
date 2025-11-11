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
  add_issue 3 \
    "Service Bus namespace $SB_NAMESPACE_NAME has disabled queues: $disabled_queues disabled at $disabled_at" \
    "Investigate why these queues are disabled and enable them if needed" \
    "Disabled queues detected"  \
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
      "Queue '$queue_name' has $dead_letter_count dead-lettered messages ($urgency priority)" \
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
  if [[ "$active_count" -gt "${ACTIVE_MESSAGE_THRESHOLD:-1000}" ]]; then
    add_issue 3 \
      "Queue '$queue_name' has $active_count active messages" \
      "Verify consumers are processing messages at an adequate rate" \
      "Large number of active messages in queue: $queue_name"
  fi
  
  # Check if queue is close to max size
  max_size_bytes=$(jq -r '.maxSizeInMegabytes' <<< "$queue_details")
  max_size_bytes=$((max_size_bytes * 1024 * 1024))
  size_bytes=$(jq -r '.sizeInBytes' <<< "$queue_details")
  size_percent=$(( (size_bytes * 100) / max_size_bytes ))
  
  if [[ "$size_percent" -gt "${SIZE_PERCENTAGE_THRESHOLD:-80}" ]]; then
    add_issue 3 \
      "Queue '$queue_name' is at ${size_percent}% of maximum size" \
      "Consider implementing auto-delete of processed messages or increasing queue size" \
      "Queue approaching size limit: $queue_name ($size_percent%)"
  fi
done

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 