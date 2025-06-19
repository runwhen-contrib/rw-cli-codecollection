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
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check for disabled queues
disabled_queues=$(jq -r '[.[] | select(.status == "Disabled") | .name] | join(", ")' <<< "$queues")
if [[ -n "$disabled_queues" ]]; then
  add_issue 2 \
    "Service Bus namespace $SB_NAMESPACE_NAME has disabled queues: $disabled_queues" \
    "Investigate why these queues are disabled and enable them if needed" \
    "Disabled queues detected"
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
  dead_letter_count=$(jq -r '.countDetails.deadLetterMessageCount' <<< "$queue_details")
  if [[ "$dead_letter_count" -gt 0 ]]; then
    add_issue 2 \
      "Queue '$queue_name' has $dead_letter_count dead-lettered messages" \
      "Investigate dead-lettered messages to identify and fix processing issues" \
      "Dead-lettered messages detected in queue: $queue_name"
  fi
  
  # Check for large active message count
  active_count=$(jq -r '.countDetails.activeMessageCount' <<< "$queue_details")
  if [[ "$active_count" -gt 1000 ]]; then
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
  
  if [[ "$size_percent" -gt 80 ]]; then
    add_issue 2 \
      "Queue '$queue_name' is at ${size_percent}% of maximum size" \
      "Consider implementing auto-delete of processed messages or increasing queue size" \
      "Queue approaching size limit: $queue_name ($size_percent%)"
  fi
done

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 