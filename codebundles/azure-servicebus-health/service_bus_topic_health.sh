#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_topic_health.sh
#
#  PURPOSE:
#    Retrieves information about Service Bus topics and subscriptions
#    and checks for health issues
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
# ---------------------------------------------------------------------------

set -euo pipefail

TOPICS_OUTPUT="service_bus_topics.json"
ISSUES_OUTPUT="service_bus_topic_issues.json"
echo "[]" > "$TOPICS_OUTPUT"
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
# 3) Get all topics in the namespace
# ---------------------------------------------------------------------------
echo "Retrieving topics for Service Bus namespace: $SB_NAMESPACE_NAME"

topics=$(az servicebus topic list \
  --namespace-name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json)

echo "$topics" > "$TOPICS_OUTPUT"
echo "Topics data saved to $TOPICS_OUTPUT"

# Count the topics
topic_count=$(jq '. | length' <<< "$topics")
echo "Found $topic_count topics in namespace $SB_NAMESPACE_NAME"

# ---------------------------------------------------------------------------
# 4) Analyze topics and subscriptions for issues
# ---------------------------------------------------------------------------
echo "Analyzing topics and subscriptions for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4" observed_at="${5:-$(date '+%Y-%m-%d %H:%M:%S')}"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              --arg o "$observed_at" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d,observed_at:$o}]' \
              <<<"$issues")
}

# Check for disabled topics
disabled_topics=$(jq -r '[.[] | select(.status == "Disabled") | .name] | join(", ")' <<< "$topics")
disabled_at=$(jq -r '[.[] | select(.status == "Disabled") | .updatedAt] | join(", ")' <<< "$topics")
if [[ -n "$disabled_topics" ]]; then
  add_issue 3 \
    "Service Bus namespace \`$SB_NAMESPACE_NAME\` has disabled topics: $disabled_topics" \
    "Investigate why these topics are disabled and enable them if needed" \
    "Disabled topics detected"  \
    "$disabled_at"
fi

# Check each topic and its subscriptions
for topic_name in $(jq -r '.[].name' <<< "$topics"); do
  echo "Checking topic: $topic_name"
  
  # Get topic details
  topic_details=$(az servicebus topic show \
    --namespace-name "$SB_NAMESPACE_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --name "$topic_name" \
    -o json)
  
  # Check if topic is close to max size
  max_size_bytes=$(jq -r '.maxSizeInMegabytes' <<< "$topic_details")
  max_size_bytes=$((max_size_bytes * 1024 * 1024))
  size_bytes=$(jq -r '.sizeInBytes' <<< "$topic_details")
  size_percent=$(( (size_bytes * 100) / max_size_bytes ))
  
  if [[ "$size_percent" -gt "${SIZE_PERCENTAGE_THRESHOLD:-80}" ]]; then
    add_issue 3 \
      "Topic \`$topic_name\` is at ${size_percent}% of maximum size" \
      "Consider implementing auto-delete of processed messages or increasing topic size" \
      "Topic approaching size limit: $topic_name ($size_percent%)"
  fi
  
  # Get subscriptions for this topic
  subscriptions=$(az servicebus topic subscription list \
    --namespace-name "$SB_NAMESPACE_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --topic-name "$topic_name" \
    -o json)
  
  sub_count=$(jq '. | length' <<< "$subscriptions")
  echo "  Found $sub_count subscriptions for topic $topic_name"
  
  # Check if there are no subscriptions
  if [[ "$sub_count" -eq 0 ]]; then
    # Get topic configuration for context
    topic_status=$(jq -r '.status' <<< "$topic_details")
    topic_size_mb=$(jq -r '.maxSizeInMegabytes' <<< "$topic_details")
    topic_current_size=$(jq -r '.sizeInBytes' <<< "$topic_details")
    topic_message_count=$(jq -r '.countDetails.activeMessageCount // 0' <<< "$topic_details")
    auto_delete_idle=$(jq -r '.autoDeleteOnIdle' <<< "$topic_details")
    
    add_issue 4 \
      "Topic \`$topic_name\` has no subscriptions" \
      "Add subscriptions to the topic or consider removing the unused topic if it's no longer needed" \
      "UNUSED TOPIC ANALYSIS:
- Topic Name: $topic_name
- Subscription Count: 0
- Topic Status: $topic_status
- Current Message Count: $topic_message_count
- Current Size: $topic_current_size bytes
- Max Size: $topic_size_mb MB
- Auto Delete on Idle: $auto_delete_idle

CONTEXT: Topics without subscriptions will accumulate published messages indefinitely since there are no consumers to process them. This can lead to:
1. Unnecessary storage consumption
2. Potential quota limit issues
3. Confusion about system architecture
4. Wasted resources and costs

INVESTIGATION STEPS:
1. Verify if this topic is intentionally unused or if subscriptions were accidentally deleted
2. Check if there are plans to add subscriptions in the future
3. Review application code to see if anything is publishing to this topic
4. Consider if this topic is part of a development/testing setup that should be cleaned up

RECOMMENDATIONS:
- If topic is truly unused: Delete the topic to clean up resources
- If temporarily unused: Consider setting appropriate auto-delete policies
- If subscriptions are planned: Document the intended usage and timeline
- If used for testing: Ensure proper lifecycle management

BUSINESS IMPACT: Minimal immediate impact but indicates potential resource waste and architectural cleanup opportunities."
  fi
  
  # Check each subscription
  for sub_name in $(jq -r '.[].name' <<< "$subscriptions"); do
    echo "  Checking subscription: $sub_name"
    
    # Get subscription details
    sub_details=$(az servicebus topic subscription show \
      --namespace-name "$SB_NAMESPACE_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --topic-name "$topic_name" \
      --name "$sub_name" \
      -o json)
    
    # Check dead letter count
    dead_letter_count=$(jq -r '.countDetails.deadLetterMessageCount // 0' <<< "$sub_details")
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
      max_delivery_count=$(jq -r '.maxDeliveryCount' <<< "$sub_details")
      status=$(jq -r '.status' <<< "$sub_details")
      auto_delete_idle=$(jq -r '.autoDeleteOnIdle' <<< "$sub_details")
      ttl=$(jq -r '.defaultMessageTimeToLive' <<< "$sub_details")
      
      add_issue $severity \
        "Subscription \`$sub_name\` for topic \`$topic_name\` has $dead_letter_count dead-lettered messages" \
        "Investigate dead-lettered messages using Azure portal or CLI. Check for processing errors, message format issues, or subscriber failures" \
        "DEAD LETTER ANALYSIS:
- Message Count: $dead_letter_count dead-lettered messages
- Severity Level: $urgency ($severity)
- Subscription: $sub_name
- Topic: $topic_name
- Subscription Status: $status
- Max Delivery Count: $max_delivery_count
- Auto Delete on Idle: $auto_delete_idle
- Default Message TTL: $ttl

CONTEXT: Dead-lettered messages indicate systematic processing failures. Messages are moved to the dead letter queue when they exceed the maximum delivery count ($max_delivery_count) or expire. This suggests either:
1. Consumer application errors or crashes during message processing
2. Message format/content issues that cause processing failures
3. Infrastructure problems preventing message delivery
4. Poison messages that consistently fail processing

INVESTIGATION STEPS:
1. Check dead letter queue properties and error descriptions
2. Sample recent dead-lettered messages to identify patterns
3. Review consumer application logs for processing errors
4. Verify message format matches expected schema
5. Check if max delivery count ($max_delivery_count) is appropriate for your use case

BUSINESS IMPACT: Failed message processing may result in data loss, delayed operations, or incomplete business workflows."
    fi
    
    # Check for large active message count
    active_count=$(jq -r '.countDetails.activeMessageCount // 0' <<< "$sub_details")
    # Ensure active_count is a valid number
    if ! [[ "$active_count" =~ ^[0-9]+$ ]]; then
      active_count=0
    fi
    if [[ "$active_count" -gt "${ACTIVE_MESSAGE_THRESHOLD:-1000}" ]]; then
      # Get additional context for backlog analysis
      scheduled_count=$(jq -r '.countDetails.scheduledMessageCount // 0' <<< "$sub_details")
      transfer_dead_letter_count=$(jq -r '.countDetails.transferDeadLetterMessageCount // 0' <<< "$sub_details")
      transfer_count=$(jq -r '.countDetails.transferMessageCount // 0' <<< "$sub_details")
      
      # Ensure all counts are valid numbers
      if ! [[ "$scheduled_count" =~ ^[0-9]+$ ]]; then scheduled_count=0; fi
      if ! [[ "$transfer_dead_letter_count" =~ ^[0-9]+$ ]]; then transfer_dead_letter_count=0; fi
      if ! [[ "$transfer_count" =~ ^[0-9]+$ ]]; then transfer_count=0; fi
      
      add_issue 3 \
        "Subscription \`$sub_name\` for topic \`$topic_name\` has $active_count active messages" \
        "Verify subscribers are processing messages at an adequate rate" \
        "MESSAGE BACKLOG ANALYSIS:
- Active Messages: $active_count (exceeds threshold of ${ACTIVE_MESSAGE_THRESHOLD:-1000})
- Scheduled Messages: $scheduled_count
- Transfer Messages: $transfer_count
- Transfer Dead Letter Messages: $transfer_dead_letter_count
- Subscription: $sub_name
- Topic: $topic_name
- Subscription Status: $status
- Max Delivery Count: $max_delivery_count

CONTEXT: Large active message counts indicate a processing backlog where messages are arriving faster than they can be consumed. This suggests:
1. Consumer throughput is insufficient for current message volume
2. Consumer applications may be down or experiencing performance issues
3. Message processing logic may be too slow or resource-intensive
4. Scaling issues with consumer infrastructure

INVESTIGATION STEPS:
1. Check consumer application health and availability
2. Monitor consumer processing rates and performance metrics
3. Verify consumer scaling configuration (auto-scaling, instance counts)
4. Analyze message processing duration and identify bottlenecks
5. Review consumer resource utilization (CPU, memory, network)
6. Check for any consumer application errors or exceptions

RECOMMENDATIONS:
- Scale out consumer instances if processing is CPU/memory bound
- Optimize message processing logic for better throughput
- Implement consumer health monitoring and alerting
- Consider message batching if supported by your application
- Review subscription configuration (prefetch count, session handling)

BUSINESS IMPACT: Message processing delays can lead to degraded user experience, delayed business operations, and potential SLA violations."
    fi
    
    # Check for disabled status
    status=$(jq -r '.status' <<< "$sub_details")
    if [[ "$status" == "Disabled" ]]; then
      add_issue 3 \
        "Subscription \`$sub_name\` for topic \`$topic_name\` is disabled" \
        "Investigate why this subscription is disabled and enable it if needed" \
        "Disabled subscription detected: $topic_name/$sub_name"  \
        "$disabled_at"
    fi
  done
done

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 