#!/usr/bin/env bash
# setup_connectivity_test.sh - Sets up networking configs for connectivity testing

set -euo pipefail

NAMESPACE_NAME="${SB_NAMESPACE_NAME:-sb-demo-primary}"
RESOURCE_GROUP="${AZ_RESOURCE_GROUP}"

echo "Setting up connectivity test configurations for $NAMESPACE_NAME"

# Get the current IP address
CURRENT_IP=$(curl -s https://api.ipify.org)
echo "Current public IP address: $CURRENT_IP"

# Configure network rules to test connectivity scenarios
echo "Configuring network rules..."

# First set default action to deny
az servicebus namespace network-rule-set create \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --default-action "Deny"

# Add the current IP to allowed IPs
az servicebus namespace network-rule-set ip-rule add \
  --resource-group "$RESOURCE_GROUP" \
  --namespace-name "$NAMESPACE_NAME" \
  --ip-address "$CURRENT_IP" \
  --action "Allow"

echo "Connectivity test setup completed. Current IP ($CURRENT_IP) is allowed."
echo "You can now run the connectivity test script."

# Instructions for testing connectivity issues
echo ""
echo "To simulate connectivity issues, run:"
echo "az servicebus namespace network-rule-set ip-rule remove --resource-group $RESOURCE_GROUP --namespace-name $NAMESPACE_NAME --ip-address $CURRENT_IP" 