#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_resource_health.sh
#
#  PURPOSE:
#    Uses Microsoft Resource Health to fetch the current availability status
#    for a Service Bus namespace and writes it to service_bus_health.json.
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
# ---------------------------------------------------------------------------

set -euo pipefail

HEALTH_OUTPUT="service_bus_health.json"
echo "[]" > "$HEALTH_OUTPUT"

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
# 2) Ensure Microsoft.ResourceHealth provider is registered
# ---------------------------------------------------------------------------
echo "Checking Microsoft.ResourceHealth provider registration…"
reg_state=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)

if [[ "$reg_state" != "Registered" ]]; then
  echo "Registering provider…"
  az provider register --namespace Microsoft.ResourceHealth
  # wait (max ~2 min)
  for i in {1..12}; do
    sleep 10
    reg_state=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv)
    [[ "$reg_state" == "Registered" ]] && break
    echo "  still $reg_state …"
  done
fi

[[ "$reg_state" != "Registered" ]] && {
  echo "ERROR: Microsoft.ResourceHealth provider not registered."
  exit 1
}

# ---------------------------------------------------------------------------
# 3) Validate required env vars
# ---------------------------------------------------------------------------
: "${SB_NAMESPACE_NAME:?Must set SB_NAMESPACE_NAME}"
: "${AZ_RESOURCE_GROUP:?Must set AZ_RESOURCE_GROUP}"

# ---------------------------------------------------------------------------
# 4) Query Resource Health
# ---------------------------------------------------------------------------
echo "Retrieving Resource Health status for $SB_NAMESPACE_NAME …"

az rest --method get \
  --url \
"https://management.azure.com/subscriptions/${subscription}/resourceGroups/${AZ_RESOURCE_GROUP}/providers/Microsoft.ServiceBus/namespaces/${SB_NAMESPACE_NAME}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview" \
  -o json > "$HEALTH_OUTPUT" || {
    echo "Failed to retrieve health status."
    exit 1
  }

echo "Health status written to $HEALTH_OUTPUT"
cat "$HEALTH_OUTPUT"
