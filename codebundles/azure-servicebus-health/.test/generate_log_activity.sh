#!/usr/bin/env bash
# generate_log_activity.sh - Generates activity to be logged in Log Analytics

set -euo pipefail

NAMESPACE_NAME="${SB_NAMESPACE_NAME:-sb-demo-primary}"
RESOURCE_GROUP="${AZ_RESOURCE_GROUP}"

echo "Generating activity for Log Analytics..."

# Get connection string
CONNECTION_STRING=$(az servicebus namespace authorization-rule keys list \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "RootManageSharedAccessKey" \
  --query "primaryConnectionString" -o tsv)

# Perform activities that generate logs
echo "Creating and deleting a temporary queue..."
TEMP_QUEUE_NAME="temp-queue-$(date +%s)"

# Create a temporary queue
az servicebus queue create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "$TEMP_QUEUE_NAME"

# Send a few messages to the queue
for i in $(seq 1 5); do
  az servicebus queue message send \
    --connection-string "$CONNECTION_STRING" \
    --queue-name "$TEMP_QUEUE_NAME" \
    --body "Test log message $i"
done

# Delete the queue to generate more activity
az servicebus queue delete \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "$TEMP_QUEUE_NAME"

# Create and delete a temporary topic
echo "Creating and deleting a temporary topic..."
TEMP_TOPIC_NAME="temp-topic-$(date +%s)"

az servicebus topic create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "$TEMP_TOPIC_NAME"

# Create a subscription
az servicebus topic subscription create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --topic-name "$TEMP_TOPIC_NAME" \
  --name "temp-sub"

# Send messages to the topic
for i in $(seq 1 5); do
  az servicebus topic message send \
    --connection-string "$CONNECTION_STRING" \
    --topic-name "$TEMP_TOPIC_NAME" \
    --body "Test log message $i for topic"
done

# Delete the topic and subscription
az servicebus topic delete \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "$TEMP_TOPIC_NAME"

echo "Log activity generation completed"
echo "Note: It may take a few minutes for logs to appear in Log Analytics" 