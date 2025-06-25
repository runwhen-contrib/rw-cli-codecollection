#!/usr/bin/env bash
# configure_security_test.sh - Sets up various security configurations for testing

set -euo pipefail

NAMESPACE_NAME="${SB_NAMESPACE_NAME:-sb-demo-primary}"
RESOURCE_GROUP="${AZ_RESOURCE_GROUP}"

echo "Setting up security test configurations for $NAMESPACE_NAME"

# Create additional authorization rules with various permissions
echo "Creating authorization rules..."
az servicebus namespace authorization-rule create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "send-only-rule" \
  --rights "Send"

az servicebus namespace authorization-rule create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "listen-only-rule" \
  --rights "Listen"

az servicebus namespace authorization-rule create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --name "send-listen-rule" \
  --rights "Send" "Listen"

# Create queue-level authorization rule
echo "Creating queue-level authorization rule..."
az servicebus queue authorization-rule create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --queue-name "orders-queue" \
  --name "queue-send-rule" \
  --rights "Send"

# Create topic-level authorization rule
echo "Creating topic-level authorization rule..."
az servicebus topic authorization-rule create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --topic-name "billing-topic" \
  --name "topic-send-rule" \
  --rights "Send"

echo "Security configurations set up successfully" 