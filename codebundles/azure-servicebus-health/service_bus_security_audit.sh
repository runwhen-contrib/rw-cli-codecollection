#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_security_audit.sh
#
#  PURPOSE:
#    Audits shared access keys and RBAC assignments for a Service Bus namespace
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
#    SAS_KEY_MAX_AGE_DAYS            Maximum age for SAS keys in days (default: 90)
# ---------------------------------------------------------------------------

set -euo pipefail

SECURITY_OUTPUT="service_bus_security.json"
ISSUES_OUTPUT="service_bus_security_issues.json"
SAS_KEY_MAX_AGE_DAYS="${SAS_KEY_MAX_AGE_DAYS:-90}"
echo "{}" > "$SECURITY_OUTPUT"
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
# 3) Get namespace resource ID
# ---------------------------------------------------------------------------
resource_id=$(az servicebus namespace show \
  --name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "id" -o tsv)

echo "Resource ID: $resource_id"

# ---------------------------------------------------------------------------
# 4) Get SAS authorization rules
# ---------------------------------------------------------------------------
echo "Retrieving authorization rules for Service Bus namespace: $SB_NAMESPACE_NAME"

# Get namespace-level authorization rules
namespace_rules=$(az servicebus namespace authorization-rule list \
  --namespace-name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json)

# Get queue-level authorization rules
queues=$(az servicebus queue list \
  --namespace-name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "[].name" -o json)

queue_rules="{}"
if [[ "$(echo "$queues" | jq 'length')" -gt 0 ]]; then
  for queue in $(echo "$queues" | jq -r '.[]'); do
    echo "Checking authorization rules for queue: $queue"
    rules=$(az servicebus queue authorization-rule list \
      --namespace-name "$SB_NAMESPACE_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --queue-name "$queue" \
      -o json)
    
    if [[ "$(echo "$rules" | jq 'length')" -gt 0 ]]; then
      queue_rules=$(echo "$queue_rules" | jq --arg q "$queue" --argjson r "$rules" \
        '. + {($q): $r}')
    fi
  done
fi

# Get topic-level authorization rules
topics=$(az servicebus topic list \
  --namespace-name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "[].name" -o json)

topic_rules="{}"
if [[ "$(echo "$topics" | jq 'length')" -gt 0 ]]; then
  for topic in $(echo "$topics" | jq -r '.[]'); do
    echo "Checking authorization rules for topic: $topic"
    rules=$(az servicebus topic authorization-rule list \
      --namespace-name "$SB_NAMESPACE_NAME" \
      --resource-group "$AZ_RESOURCE_GROUP" \
      --topic-name "$topic" \
      -o json)
    
    if [[ "$(echo "$rules" | jq 'length')" -gt 0 ]]; then
      topic_rules=$(echo "$topic_rules" | jq --arg t "$topic" --argjson r "$rules" \
        '. + {($t): $r}')
    fi
  done
fi

# ---------------------------------------------------------------------------
# 5) Get RBAC assignments
# ---------------------------------------------------------------------------
echo "Retrieving RBAC assignments for Service Bus namespace"

rbac_assignments=$(az role assignment list \
  --scope "$resource_id" \
  -o json)

# ---------------------------------------------------------------------------
# 6) Combine security data
# ---------------------------------------------------------------------------
security_data=$(jq -n \
  --argjson namespace_rules "$namespace_rules" \
  --argjson queue_rules "$queue_rules" \
  --argjson topic_rules "$topic_rules" \
  --argjson rbac_assignments "$rbac_assignments" \
  '{namespace_rules: $namespace_rules, queue_rules: $queue_rules, topic_rules: $topic_rules, rbac_assignments: $rbac_assignments}')

echo "$security_data" > "$SECURITY_OUTPUT"
echo "Security data saved to $SECURITY_OUTPUT"

# ---------------------------------------------------------------------------
# 7) Analyze security configuration for issues
# ---------------------------------------------------------------------------
echo "Analyzing security configuration for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check for RootManageSharedAccessKey
has_root_key=$(jq '.namespace_rules[] | select(.name == "RootManageSharedAccessKey") | length > 0' <<< "$security_data")
if [[ "$has_root_key" == "true" ]]; then
  add_issue 4 \
    "Default RootManageSharedAccessKey is present on Service Bus namespace $SB_NAMESPACE_NAME" \
    "Consider using more granular authorization rules or RBAC instead of the root key" \
    "Default root key should be rotated or removed for security best practices"
fi

# Check for overly permissive rules (Manage rights)
namespace_manage_keys=$(jq '.namespace_rules[] | select(.rights | contains(["Manage"])) | .name' <<< "$security_data" | jq -s 'join(", ")')
if [[ "$namespace_manage_keys" != '""' ]]; then
  add_issue 4 \
    "Namespace-level authorization rules with Manage rights found: $namespace_manage_keys" \
    "Review if Manage rights are necessary or if more restrictive rights can be used" \
    "Manage rights grant full control over the namespace"
fi

# Check if RBAC is being used
rbac_count=$(jq '.rbac_assignments | length' <<< "$security_data")
if [[ "$rbac_count" -eq 0 ]]; then
  add_issue 4 \
    "No RBAC assignments found for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Consider using Azure RBAC for more granular and auditable access control" \
    "RBAC provides better security controls than SAS keys"
fi

# Check for per-entity rules (which indicate good security practice)
queue_rule_count=$(jq '.queue_rules | keys | length' <<< "$security_data")
topic_rule_count=$(jq '.topic_rules | keys | length' <<< "$security_data")
if [[ "$queue_rule_count" -eq 0 && "$topic_rule_count" -eq 0 ]]; then
  add_issue 4 \
    "No queue or topic level authorization rules found for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Consider using entity-specific authorization rules for better security isolation" \
    "Entity-specific rules provide better security isolation than namespace-level rules"
fi

# Check for overly permissive RBAC roles
owner_roles=$(jq '.rbac_assignments[] | select(.roleDefinitionName == "Owner") | .principalName' <<< "$security_data" | jq -s 'join(", ")')
if [[ "$owner_roles" != '""' ]]; then
  add_issue 4 \
    "Owner role assignments found for Service Bus namespace: $owner_roles" \
    "Review if Owner role is necessary or if more restrictive roles can be used" \
    "Owner role grants full control over the namespace"
fi

# Check for system-assigned managed identity
identity_type=$(az servicebus namespace show \
  --name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "identity.type" -o tsv 2>/dev/null || echo "None")

if [[ "$identity_type" == "None" ]]; then
  add_issue 4 \
    "No managed identity configured for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Consider assigning a managed identity for secure authentication with other Azure services" \
    "Managed identities eliminate the need to store credentials in code"
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 