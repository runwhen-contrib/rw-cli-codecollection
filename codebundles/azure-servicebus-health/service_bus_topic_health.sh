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
  disabled_count=$(jq -r '[.[] | select(.status == "Disabled")] | length' <<< "$topics")
  add_issue 3 \
    "Service Bus namespace $SB_NAMESPACE_NAME has $disabled_count disabled topic(s): $disabled_topics" \
    "Investigate why these topics are disabled and enable them if needed" \
    "DISABLED TOPIC ANALYSIS:
- Disabled Topic(s): $disabled_topics
- Count: $disabled_count
- Last Updated: $disabled_at
- Namespace: $SB_NAMESPACE_NAME
- Resource Group: $AZ_RESOURCE_GROUP

CONTEXT: Disabled topics cannot send or receive messages, which disrupts message flow to all subscriptions and can cause widespread application failures. Topics may be disabled:
1. Manually by administrators during maintenance
2. Automatically by Azure due to policy violations
3. As a result of subscription or namespace suspension
4. Due to quota exhaustions or security concerns

INVESTIGATION STEPS:
1. Check Azure portal for topic status and any warning messages
2. Review Azure Activity Log for who disabled the topic and when
3. Verify no ongoing maintenance or security incidents
4. Check for any namespace-level issues affecting multiple topics
5. Review application logs for errors around the disabled time ($disabled_at)
6. Identify all subscriptions affected by the disabled topic(s)
7. Verify topic configuration and policies are correct

RECOMMENDATIONS:
- Re-enable topics if disabled unintentionally
- Document maintenance windows if intentionally disabled
- Implement monitoring alerts for topic status changes
- Review access control to prevent unauthorized modifications
- Verify publisher applications have proper error handling for disabled topics
- Notify all subscriber teams about the topic status

BUSINESS IMPACT: Disabled topics cause message delivery failures across all subscriptions, widespread application errors, and disrupted business workflows affecting multiple downstream systems. Requires immediate attention."  \
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
    # Get additional context for size analysis
    max_size_mb=$(jq -r '.maxSizeInMegabytes' <<< "$topic_details")
    message_count=$(jq -r '.countDetails.activeMessageCount // 0' <<< "$topic_details")
    scheduled_count=$(jq -r '.countDetails.scheduledMessageCount // 0' <<< "$topic_details")
    topic_status=$(jq -r '.status' <<< "$topic_details")
    auto_delete_idle=$(jq -r '.autoDeleteOnIdle' <<< "$topic_details")
    enable_partitioning=$(jq -r '.enablePartitioning' <<< "$topic_details")
    subscription_count=$(jq -r '.subscriptionCount // 0' <<< "$topic_details")
    
    add_issue 3 \
      "Topic $topic_name is at ${size_percent}% of maximum size" \
      "Consider implementing auto-delete of processed messages or increasing topic size" \
      "TOPIC SIZE CAPACITY ANALYSIS:
- Current Size: $size_bytes bytes (${size_percent}% of capacity)
- Maximum Size: $max_size_mb MB ($max_size_bytes bytes)
- Active Message Count: $message_count
- Scheduled Message Count: $scheduled_count
- Topic Name: $topic_name
- Topic Status: $topic_status
- Subscription Count: $subscription_count
- Auto Delete on Idle: $auto_delete_idle
- Partitioning Enabled: $enable_partitioning

CONTEXT: Topic approaching storage capacity limit indicates that messages are accumulating faster than subscriptions are consuming them. This can lead to:
1. Topic throttling or message rejection when limit is reached
2. Publisher application failures due to inability to send new messages
3. Increased latency in message processing across all subscriptions
4. Potential data loss if messages are rejected
5. Service disruption affecting all subscribers ($subscription_count subscription(s))

INVESTIGATION STEPS:
1. Verify all $subscription_count subscription(s) are actively processing messages
2. Check if subscriptions are properly completing/deleting messages after processing
3. Review message retention policies and auto-delete configuration
4. Analyze message size distribution to identify large messages
5. Check subscription dead-letter queues for messages contributing to size
6. Review historical growth patterns to predict when limit will be reached
7. Verify if partitioning is enabled and functioning correctly
8. Check for inactive or abandoned subscriptions

RECOMMENDATIONS:
- Increase topic maximum size if within namespace quota limits
- Ensure all subscriptions have active consumers processing messages
- Configure auto-delete on idle if appropriate: $auto_delete_idle
- Enable partitioning to increase throughput and capacity (currently: $enable_partitioning)
- Review message TTL settings to automatically expire old messages
- Remove inactive subscriptions that may be holding messages
- Scale out subscription consumers to process backlog faster
- Investigate and address any dead-letter message accumulation

BUSINESS IMPACT: Reaching topic capacity will cause message rejection, publisher failures, and potential data loss affecting all $subscription_count subscription(s). Immediate action required to prevent service disruption."
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
      # Get additional context for disabled subscription
      updated_at=$(jq -r '.updatedAt' <<< "$sub_details")
      max_delivery_count=$(jq -r '.maxDeliveryCount' <<< "$sub_details")
      message_count=$(jq -r '.countDetails.activeMessageCount // 0' <<< "$sub_details")
      dead_letter_count=$(jq -r '.countDetails.deadLetterMessageCount // 0' <<< "$sub_details")
      
      add_issue 3 \
        "Subscription $sub_name for topic $topic_name is disabled" \
        "Investigate why this subscription is disabled and enable it if needed" \
        "DISABLED SUBSCRIPTION ANALYSIS:
- Subscription: $sub_name
- Topic: $topic_name
- Status: Disabled
- Last Updated: $updated_at
- Active Message Count: $message_count
- Dead Letter Message Count: $dead_letter_count
- Max Delivery Count: $max_delivery_count
- Namespace: $SB_NAMESPACE_NAME
- Resource Group: $AZ_RESOURCE_GROUP

CONTEXT: Disabled subscriptions stop receiving messages from their topic, causing message delivery failures for specific consumers. While the topic continues to function for other subscriptions, this subscription will miss all messages published during the disabled period. Subscriptions may be disabled:
1. Manually by administrators during maintenance or troubleshooting
2. Automatically by Azure due to policy violations or quota issues
3. As part of subscription or namespace-level issues
4. To stop message flow during consumer application updates

INVESTIGATION STEPS:
1. Check Azure portal for subscription status and any warning messages
2. Review Azure Activity Log for who disabled the subscription and when ($updated_at)
3. Verify consumer application is ready to process messages before re-enabling
4. Check if disabled as part of maintenance or troubleshooting effort
5. Review any accumulated messages ($message_count active, $dead_letter_count dead-letter)
6. Verify subscription configuration and policies are correct
7. Check namespace and topic status for related issues

RECOMMENDATIONS:
- Re-enable subscription if disabled unintentionally
- Ensure consumer application is healthy before enabling
- Address any message backlog ($message_count messages) that accumulated during downtime
- Review and clear dead-letter queue if needed ($dead_letter_count messages)
- Document maintenance windows if intentionally disabled
- Implement monitoring alerts for subscription status changes
- Consider message recovery strategy for missed messages during disabled period

BUSINESS IMPACT: Disabled subscription causes message delivery failures for specific consumer applications, leading to data loss, missed events, and disrupted workflows for the affected system. Messages published while disabled cannot be recovered."  \
        "$updated_at"
    fi
  done
done

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 