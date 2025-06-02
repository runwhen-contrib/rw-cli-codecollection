#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_alerts_check.sh
#
#  PURPOSE:
#    Checks for the presence and configuration of Azure Monitor alerts
#    for a Service Bus namespace
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
# ---------------------------------------------------------------------------

set -euo pipefail

ALERTS_OUTPUT="service_bus_alerts.json"
ISSUES_OUTPUT="service_bus_alerts_issues.json"
echo "{}" > "$ALERTS_OUTPUT"
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
echo "Getting resource ID for Service Bus namespace: $SB_NAMESPACE_NAME"

resource_id=$(az servicebus namespace show \
  --name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "id" -o tsv)

echo "Resource ID: $resource_id"

# ---------------------------------------------------------------------------
# 4) Get Azure Monitor alert rules for the namespace
# ---------------------------------------------------------------------------
echo "Retrieving alert rules for Service Bus namespace: $SB_NAMESPACE_NAME"

# Get all alert rules in the resource group
all_alerts=$(az monitor metrics alert list \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json)

# Filter for Service Bus namespace alert rules
servicebus_alerts=$(echo "$all_alerts" | jq --arg id "$resource_id" '[.[] | select(.scopes[] | contains($id))]')

# Get action groups
action_groups=$(az monitor action-group list \
  -o json)

# ---------------------------------------------------------------------------
# 5) Check if recommended alert rules exist
# ---------------------------------------------------------------------------
echo "Checking for recommended Service Bus alert rules..."

# Define recommended alert rules
recommended_alerts=$(cat <<EOF
[
  {
    "name": "Server Errors",
    "metric": "ServerErrors",
    "operator": "GreaterThan",
    "threshold": 0,
    "severity": 1,
    "description": "Alerts when any server errors occur in the Service Bus namespace."
  },
  {
    "name": "User Errors",
    "metric": "UserErrors",
    "operator": "GreaterThan",
    "threshold": 10,
    "severity": 2,
    "description": "Alerts when a significant number of user errors occur."
  },
  {
    "name": "Throttled Requests",
    "metric": "ThrottledRequests",
    "operator": "GreaterThan",
    "threshold": 0,
    "severity": 2,
    "description": "Alerts when requests are being throttled."
  },
  {
    "name": "High Active Message Count",
    "metric": "ActiveMessages",
    "operator": "GreaterThan",
    "threshold": 1000,
    "severity": 3,
    "description": "Alerts when a large number of messages are waiting to be processed."
  },
  {
    "name": "Dead-lettered Messages",
    "metric": "DeadletteredMessages",
    "operator": "GreaterThan",
    "threshold": 0,
    "severity": 2,
    "description": "Alerts when messages are moved to the dead-letter queue."
  },
  {
    "name": "Namespace Size",
    "metric": "Size",
    "operator": "GreaterThan",
    "threshold": 80,
    "severity": 2,
    "description": "Alerts when the namespace is approaching its size limit."
  }
]
EOF
)

# ---------------------------------------------------------------------------
# 6) Combine alerts data
# ---------------------------------------------------------------------------
alerts_data=$(jq -n \
  --argjson existing "$servicebus_alerts" \
  --argjson recommended "$recommended_alerts" \
  --argjson action_groups "$action_groups" \
  '{
    existing_alerts: $existing,
    recommended_alerts: $recommended,
    action_groups: $action_groups,
    existing_count: ($existing | length),
    action_groups_count: ($action_groups | length)
  }')

echo "$alerts_data" > "$ALERTS_OUTPUT"
echo "Alerts data saved to $ALERTS_OUTPUT"

# ---------------------------------------------------------------------------
# 7) Analyze alerts configuration for issues
# ---------------------------------------------------------------------------
echo "Analyzing alerts configuration for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check if any alerts exist
existing_count=$(jq '.existing_count' <<< "$alerts_data")
if [[ "$existing_count" -eq 0 ]]; then
  add_issue 2 \
    "No alert rules found for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Configure recommended Azure Monitor alert rules for monitoring Service Bus health" \
    "Monitoring alerts are essential for proactive issue detection"
fi

# Check for action groups
action_groups_count=$(jq '.action_groups_count' <<< "$alerts_data")
if [[ "$action_groups_count" -eq 0 ]]; then
  add_issue 2 \
    "No action groups found for alerting" \
    "Create action groups to define how alerts should be sent (email, SMS, webhook, etc.)" \
    "Action groups are required for alerts to notify the appropriate personnel"
fi

# Check for each recommended alert
for i in $(seq 0 $(jq '.recommended_alerts | length - 1' <<< "$alerts_data")); do
  recommended_name=$(jq -r ".recommended_alerts[$i].name" <<< "$alerts_data")
  recommended_metric=$(jq -r ".recommended_alerts[$i].metric" <<< "$alerts_data")
  recommended_desc=$(jq -r ".recommended_alerts[$i].description" <<< "$alerts_data")
  
  # Check if this recommended alert exists
  alert_exists=$(jq --arg metric "$recommended_metric" '.existing_alerts[] | select(.criteria.allOf[].metricName == $metric) | .name' <<< "$alerts_data")
  
  if [[ -z "$alert_exists" ]]; then
    # Determine severity based on the recommended alert's severity
    rec_severity=$(jq -r ".recommended_alerts[$i].severity" <<< "$alerts_data")
    
    add_issue "$rec_severity" \
      "Missing recommended alert rule: $recommended_name for Service Bus namespace $SB_NAMESPACE_NAME" \
      "Configure an alert rule for the $recommended_metric metric" \
      "$recommended_desc"
  fi
done

# Check existing alerts for action groups
if [[ "$existing_count" -gt 0 && "$action_groups_count" -gt 0 ]]; then
  for i in $(seq 0 $(jq '.existing_alerts | length - 1' <<< "$alerts_data")); do
    alert_name=$(jq -r ".existing_alerts[$i].name" <<< "$alerts_data")
    has_actions=$(jq -r ".existing_alerts[$i].actions | length > 0" <<< "$alerts_data")
    
    if [[ "$has_actions" == "false" ]]; then
      add_issue 2 \
        "Alert rule '$alert_name' has no action groups configured" \
        "Associate action groups with this alert rule to ensure notifications are sent" \
        "Alerts without action groups won't notify anyone when triggered"
    fi
  done
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 