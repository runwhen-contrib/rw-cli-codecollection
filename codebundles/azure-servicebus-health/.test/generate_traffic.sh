#!/usr/bin/env bash
# generate_traffic.sh - Creates traffic to generate meaningful metrics

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

NAMESPACE_NAME="${SB_NAMESPACE_NAME:-sb-demo-primary}"
RESOURCE_GROUP="${AZ_RESOURCE_GROUP}"
DURATION_MINUTES="${DURATION_MINUTES:-15}"
INTENSITY="${INTENSITY:-medium}"  # low, medium, high

# Get connection string
CONNECTION_STRING=$(az servicebus namespace authorization-rule keys list \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "RootManageSharedAccessKey" \
  --query "primaryConnectionString" -o tsv)

# Set parameters based on intensity
case "$INTENSITY" in
  "low")
    SEND_INTERVAL=5
    MESSAGE_COUNT=5
    ;;
  "medium")
    SEND_INTERVAL=2
    MESSAGE_COUNT=10
    ;;
  "high")
    SEND_INTERVAL=0.5
    MESSAGE_COUNT=20
    ;;
  *)
    echo "Unknown intensity: $INTENSITY, using medium"
    SEND_INTERVAL=2
    MESSAGE_COUNT=10
    ;;
esac

# Calculate end time
END_TIME=$(date -d "+$DURATION_MINUTES minutes" +%s)

echo "Generating traffic for $DURATION_MINUTES minutes at $INTENSITY intensity"
echo "Press Ctrl+C to stop early"

# Create 20 API calls with invalid credentials to generate throttling events
echo "Generating some throttled requests..."
for i in $(seq 1 20); do
  # Use invalid connection string to generate throttled requests
  INVALID_CS="Endpoint=sb://$NAMESPACE_NAME.servicebus.windows.net/;SharedAccessKeyName=RootManageSharedAccessKey;SharedAccessKey=InvalidKeyThatWillCauseThrottling"
  az servicebus queue list --connection-string "$INVALID_CS" 2>/dev/null || true
  sleep 0.1
done

# Main traffic generation loop
while [ $(date +%s) -lt $END_TIME ]; do
  # Send batch of messages to queue
  for i in $(seq 1 $MESSAGE_COUNT); do
    az servicebus queue message send \
      --connection-string "$CONNECTION_STRING" \
      --queue-name "orders-queue" \
      --body "Traffic generation message $(date)" \
      --time-to-live "PT1H" \
      --correlation-id "traffic-gen-$(date +%s)" \
      --content-type "application/json" \
      --label "traffic-generation"
  done
  
  # Send batch of messages to topic
  for i in $(seq 1 $MESSAGE_COUNT); do
    az servicebus topic message send \
      --connection-string "$CONNECTION_STRING" \
      --topic-name "billing-topic" \
      --body "Traffic generation message $(date)" \
      --time-to-live "PT1H" \
      --correlation-id "traffic-gen-$(date +%s)" \
      --content-type "application/json" \
      --label "traffic-generation"
  done
  
  # Receive and complete some messages from the queue
  MESSAGES=$(az servicebus queue message receive-batch \
    --connection-string "$CONNECTION_STRING" \
    --queue-name "orders-queue" \
    --max-message-count $((MESSAGE_COUNT / 2)) \
    --peek-lock true)
  
  # Complete the messages if any were received
  if [[ "$MESSAGES" != "[]" ]]; then
    for MESSAGE in $(echo "$MESSAGES" | jq -c '.[]'); do
      SEQUENCE_NUMBER=$(echo "$MESSAGE" | jq -r '.sequenceNumber')
      LOCK_TOKEN=$(echo "$MESSAGE" | jq -r '.lockToken')
      
      az servicebus queue message complete \
        --connection-string "$CONNECTION_STRING" \
        --queue-name "orders-queue" \
        --sequence-number "$SEQUENCE_NUMBER" \
        --lock-token "$LOCK_TOKEN"
    done
  fi
  
  echo "Traffic generation cycle completed at $(date)"
  sleep $SEND_INTERVAL
done

echo "Traffic generation completed" 