#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_disaster_recovery.sh
#
#  PURPOSE:
#    Checks the geo-disaster recovery configuration and health for a Service Bus namespace
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
# ---------------------------------------------------------------------------

set -euo pipefail

DR_OUTPUT="service_bus_dr.json"
ISSUES_OUTPUT="service_bus_dr_issues.json"
echo "{}" > "$DR_OUTPUT"
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
# 3) Check if disaster recovery is configured
# ---------------------------------------------------------------------------
echo "Checking disaster recovery configuration for $SB_NAMESPACE_NAME..."

# Get namespace details
namespace_info=$(az servicebus namespace show \
  --name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "sku.name" -o tsv)

# Check if disaster recovery is supported (Premium tier only)
if [[ "$namespace_info" != "Premium" ]]; then
  echo "Disaster recovery is only supported for Premium tier namespaces. Current tier: $namespace_info"
  dr_config="{\"dr_supported\": false, \"tier\": \"$namespace_info\", \"pairings\": []}"
  echo "$dr_config" > "$DR_OUTPUT"
else
  # Get disaster recovery configurations
  echo "Namespace is Premium tier, checking DR configurations..."
  dr_config=$(az servicebus georecovery-alias list \
    --namespace-name "$SB_NAMESPACE_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    -o json 2>/dev/null || echo "[]")
  
  # Format the output
  formatted_dr=$(jq -n \
    --arg tier "$namespace_info" \
    --argjson dr "$dr_config" \
    '{dr_supported: true, tier: $tier, pairings: $dr}')
  
  echo "$formatted_dr" > "$DR_OUTPUT"
  echo "Disaster recovery configuration saved to $DR_OUTPUT"
fi

# ---------------------------------------------------------------------------
# 4) Analyze DR configuration for issues
# ---------------------------------------------------------------------------
echo "Analyzing disaster recovery configuration for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

dr_supported=$(jq -r '.dr_supported' < "$DR_OUTPUT")
tier=$(jq -r '.tier' < "$DR_OUTPUT")

# Check if DR is supported but not configured
if [[ "$dr_supported" == "true" ]]; then
  pairing_count=$(jq '.pairings | length' < "$DR_OUTPUT")
  
  if [[ "$pairing_count" -eq 0 ]]; then
    add_issue 4 \
      "No geo-disaster recovery configured for Premium tier Service Bus namespace $SB_NAMESPACE_NAME" \
      "Consider configuring geo-disaster recovery pairing for business continuity" \
      "Premium namespace without disaster recovery configuration"
  else
    # Check each pairing
    for i in $(seq 0 $((pairing_count-1))); do
      alias_name=$(jq -r ".pairings[$i].name" < "$DR_OUTPUT")
      provisioning_state=$(jq -r ".pairings[$i].provisioningState" < "$DR_OUTPUT")
      role=$(jq -r ".pairings[$i].role" < "$DR_OUTPUT")
      partner_namespace=$(jq -r ".pairings[$i].partnerNamespace" < "$DR_OUTPUT")
      
      echo "Checking DR pairing: $alias_name (Role: $role)"
      
      # Check provisioning state
      if [[ "$provisioning_state" != "Succeeded" ]]; then
        add_issue 1 \
          "Disaster recovery pairing '$alias_name' is in state '$provisioning_state'" \
          "Investigate why the DR pairing is not in Succeeded state and remediate" \
          "DR pairing is not in Succeeded state: $provisioning_state"
      fi
      
      # Check if this is primary
      if [[ "$role" == "Primary" ]]; then
        # For primary, check last sync time
        echo "This namespace is Primary in the DR configuration"
        # Try to get replication status (might not be available in CLI)
        # This might need manual review in Azure Portal
        add_issue 4 \
          "Service Bus namespace $SB_NAMESPACE_NAME is configured as Primary in DR pairing '$alias_name'" \
          "Periodically test failover procedures and verify replication status in Azure Portal" \
          "Primary namespace in DR pairing with $partner_namespace"
      elif [[ "$role" == "Secondary" ]]; then
        echo "This namespace is Secondary in the DR configuration"
        add_issue 4 \
          "Service Bus namespace $SB_NAMESPACE_NAME is configured as Secondary in DR pairing '$alias_name'" \
          "Ensure applications are configured to use the alias name for connection strings" \
          "Secondary namespace in DR pairing with $partner_namespace"
      elif [[ "$role" == "PrimaryBeingSeconded" ]]; then
        add_issue 4 \
          "DR pairing '$alias_name' is in transitional state 'PrimaryBeingSeconded'" \
          "Wait for the pairing to complete initialization" \
          "DR pairing is in transitional state"
      fi
    done
  fi
else
  add_issue 4 \
    "Geo-disaster recovery is not supported for $tier tier Service Bus namespace $SB_NAMESPACE_NAME" \
    "Consider upgrading to Premium tier if geo-disaster recovery is required for business continuity" \
    "Current tier ($tier) does not support geo-disaster recovery"
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 