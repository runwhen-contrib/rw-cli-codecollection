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
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check for disabled topics
disabled_topics=$(jq -r '[.[] | select(.status == "Disabled") | .name] | join(", ")' <<< "$topics")
if [[ -n "$disabled_topics" ]]; then
  add_issue 3 \
    "Service Bus namespace $SB_NAMESPACE_NAME has disabled topics: $disabled_topics" \
    "Investigate why these topics are disabled and enable them if needed" \
    "Disabled topics detected"
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
  
  if [[ "$size_percent" -gt 80 ]]; then
    add_issue 3 \
      "Topic '$topic_name' is at ${size_percent}% of maximum size" \
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
    add_issue 3 \
      "Topic '$topic_name' has no subscriptions" \
      "Add subscriptions to the topic or consider removing the unused topic" \
      "No subscriptions found for topic: $topic_name"
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
    dead_letter_count=$(jq -r '.countDetails.deadLetterMessageCount' <<< "$sub_details")
    if [[ "$dead_letter_count" -gt 0 ]]; then
      add_issue 3 \
        "Subscription '$sub_name' for topic '$topic_name' has $dead_letter_count dead-lettered messages" \
        "Investigate dead-lettered messages to identify and fix processing issues" \
        "Dead-lettered messages detected in subscription: $topic_name/$sub_name"
    fi
    
    # Check for large active message count
    active_count=$(jq -r '.countDetails.activeMessageCount' <<< "$sub_details")
    if [[ "$active_count" -gt 1000 ]]; then
      add_issue 3 \
        "Subscription '$sub_name' for topic '$topic_name' has $active_count active messages" \
        "Verify subscribers are processing messages at an adequate rate" \
        "Large number of active messages in subscription: $topic_name/$sub_name"
    fi
    
    # Check for disabled status
    status=$(jq -r '.status' <<< "$sub_details")
    if [[ "$status" == "Disabled" ]]; then
      add_issue 3 \
        "Subscription '$sub_name' for topic '$topic_name' is disabled" \
        "Investigate why this subscription is disabled and enable it if needed" \
        "Disabled subscription detected: $topic_name/$sub_name"
    fi
  done
done

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 