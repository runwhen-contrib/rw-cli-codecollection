#!/usr/bin/env bash
# inject_test_messages.sh - Injects test messages into Service Bus queues and topics

set -euo pipefail

NAMESPACE_NAME="${SB_NAMESPACE_NAME:-sb-demo-primary}"
RESOURCE_GROUP="${AZ_RESOURCE_GROUP}"

# Get connection string
CONNECTION_STRING=$(az servicebus namespace authorization-rule keys list \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "RootManageSharedAccessKey" \
  --query "primaryConnectionString" -o tsv)

# Function to send messages to a queue
send_to_queue() {
  local queue_name=$1
  local message_count=$2
  local include_dead_letter=$3
  
  echo "Sending $message_count messages to queue: $queue_name"
  
  for i in $(seq 1 "$message_count"); do
    az servicebus queue message send \
      --connection-string "$CONNECTION_STRING" \
      --queue-name "$queue_name" \
      --body "Test message $i for queue $queue_name $(date)" \
      --time-to-live "P1D"
  done
  
  # If specified, create some dead-lettered messages
  if [[ "$include_dead_letter" == "true" ]]; then
    echo "Creating dead-lettered messages in queue: $queue_name"
    
    # Send messages that will be moved to dead-letter queue after max delivery count
    for i in $(seq 1 5); do
      # Create a message with a specific message ID
      MSG_ID="test-dlq-$i-$(date +%s)"
      
      az servicebus queue message send \
        --connection-string "$CONNECTION_STRING" \
        --queue-name "$queue_name" \
        --body "Message that will be dead-lettered" \
        --message-id "$MSG_ID"
      
      # Peek and lock the message repeatedly until it gets dead-lettered
      for j in $(seq 1 11); do  # More than max delivery count
        MESSAGE=$(az servicebus queue message peek \
          --connection-string "$CONNECTION_STRING" \
          --queue-name "$queue_name" \
          --query "[?messageId=='$MSG_ID']" -o json)
        
        if [[ -z "$MESSAGE" || "$MESSAGE" == "[]" ]]; then
          break
        fi
        
        # Receive and abandon to increment delivery count
        az servicebus queue message receive \
          --connection-string "$CONNECTION_STRING" \
          --queue-name "$queue_name" \
          --peek-lock true | \
        az servicebus queue message abandon \
          --connection-string "$CONNECTION_STRING" \
          --queue-name "$queue_name"
          
        sleep 1
      done
    done
  fi
}

# Function to send messages to a topic
send_to_topic() {
  local topic_name=$1
  local message_count=$2
  
  echo "Sending $message_count messages to topic: $topic_name"
  
  for i in $(seq 1 "$message_count"); do
    az servicebus topic message send \
      --connection-string "$CONNECTION_STRING" \
      --topic-name "$topic_name" \
      --body "Test message $i for topic $topic_name $(date)" \
      --time-to-live "P1D"
  done
}

# Inject messages to queues and topics
send_to_queue "orders-queue" 50 "true"
send_to_queue "legacy-disabled" 5 "false"
send_to_topic "billing-topic" 30

echo "Message injection completed" 