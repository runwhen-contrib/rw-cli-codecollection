#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_related_resources.sh
#
#  PURPOSE:
#    Discovers and maps Azure resources that are connected to or depend on 
#    the Service Bus namespace
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

RELATED_OUTPUT="service_bus_related_resources.json"
ISSUES_OUTPUT="service_bus_related_resources_issues.json"
echo "{}" > "$RELATED_OUTPUT"
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
# 4) Find related resources using different approaches
# ---------------------------------------------------------------------------
echo "Discovering resources related to Service Bus namespace: $SB_NAMESPACE_NAME"

# 4.1) Check for Event Grid subscriptions using the Service Bus
echo "Checking for Event Grid subscriptions..."
event_grid_subs_raw=$(az eventgrid event-subscription list \
  --source-resource-id "$resource_id" \
  -o json 2>/dev/null || echo "[]")
# Validate JSON before using
event_grid_subs=$(echo "$event_grid_subs_raw" | jq . 2>/dev/null || echo "[]")

# 4.2) Check for Private Endpoints connected to the Service Bus
echo "Checking for Private Endpoints..."
private_endpoints_raw=$(az network private-endpoint list \
  --query "[?contains(privateLinkServiceConnections[].privateLinkServiceId, '$resource_id')]" \
  -o json 2>/dev/null || echo "[]")
# Validate JSON before using
private_endpoints=$(echo "$private_endpoints_raw" | jq . 2>/dev/null || echo "[]")

# 4.3) Check for Logic Apps potentially using the Service Bus
echo "Checking for Logic Apps potentially using Service Bus..."
# This is a heuristic search, we're looking for Logic Apps in the same resource group
# that might be using the Service Bus
logic_apps_raw=$(az logic workflow list \
  --resource-group "$AZ_RESOURCE_GROUP" \
  -o json 2>/dev/null || echo "[]")
# Validate JSON before using
logic_apps=$(echo "$logic_apps_raw" | jq . 2>/dev/null || echo "[]")

# 4.4) Check for App Service configurations potentially using the Service Bus
echo "Checking for App Services potentially using Service Bus..."
web_apps_raw=$(az webapp list \
  --query "[?contains(to_string(siteConfig.appSettings), '$SB_NAMESPACE_NAME')]" \
  -o json 2>/dev/null || echo "[]")
# Validate JSON before using
web_apps=$(echo "$web_apps_raw" | jq . 2>/dev/null || echo "[]")

# 4.5) Check for Azure Functions potentially using the Service Bus
echo "Checking for Azure Functions potentially using Service Bus..."
function_apps_raw=$(az functionapp list \
  --query "[?contains(to_string(siteConfig.appSettings), '$SB_NAMESPACE_NAME')]" \
  -o json 2>/dev/null || echo "[]")
# Validate JSON before using
function_apps=$(echo "$function_apps_raw" | jq . 2>/dev/null || echo "[]")

# 4.6) Check for diagnostic settings sending data to Log Analytics or Storage
echo "Checking for diagnostic settings..."
diag_settings_raw=$(az monitor diagnostic-settings list \
  --resource "$resource_id" \
  -o json 2>/dev/null || echo "[]")
# Validate JSON before using
diag_settings=$(echo "$diag_settings_raw" | jq . 2>/dev/null || echo "[]")

# 4.7) Check for Azure Monitor action groups using Service Bus
echo "Checking for Azure Monitor action groups..."
action_groups_raw=$(az monitor action-group list \
  --query "[?contains(to_string(servicebus), '$SB_NAMESPACE_NAME')]" \
  -o json 2>/dev/null || echo "[]")
# Validate JSON before using
action_groups=$(echo "$action_groups_raw" | jq . 2>/dev/null || echo "[]")

# ---------------------------------------------------------------------------
# 5) Combine related resources data
# ---------------------------------------------------------------------------
related_data=$(jq -n \
  --argjson event_grid "$event_grid_subs" \
  --argjson private_endpoints "$private_endpoints" \
  --argjson logic_apps "$logic_apps" \
  --argjson web_apps "$web_apps" \
  --argjson function_apps "$function_apps" \
  --argjson diag_settings "$diag_settings" \
  --argjson action_groups "$action_groups" \
  '{
    event_grid_subscriptions: $event_grid,
    private_endpoints: $private_endpoints,
    logic_apps: $logic_apps,
    web_apps: $web_apps,
    function_apps: $function_apps,
    diagnostic_settings: $diag_settings,
    action_groups: $action_groups,
    summary: {
      event_grid_count: ($event_grid | length),
      private_endpoint_count: ($private_endpoints | length),
      logic_app_count: ($logic_apps | length),
      web_app_count: ($web_apps | length),
      function_app_count: ($function_apps | length),
      diagnostic_settings_count: ($diag_settings | length),
      action_group_count: ($action_groups | length)
    }
  }')

echo "$related_data" > "$RELATED_OUTPUT"
echo "Related resources data saved to $RELATED_OUTPUT"

# ---------------------------------------------------------------------------
# 6) Analyze related resources for issues
# ---------------------------------------------------------------------------
echo "Analyzing related resources for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check if private endpoints are configured (important for security)
private_endpoint_count=$(jq '.summary.private_endpoint_count' <<< "$related_data")
if [[ "$private_endpoint_count" -eq 0 ]]; then
  add_issue 4 \
    "No private endpoints found for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Consider using private endpoints to securely access the Service Bus from your virtual network" \
    "Private endpoints enhance security by allowing access to Service Bus over a private link"
fi

# Check if diagnostic settings are configured
diag_settings_count=$(jq '.summary.diagnostic_settings_count' <<< "$related_data")
if [[ "$diag_settings_count" -eq 0 ]]; then
  add_issue 4 \
    "No diagnostic settings found for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Configure diagnostic settings to send logs to Log Analytics or a Storage Account" \
    "Diagnostic settings are important for monitoring and troubleshooting"
fi

# Informational items about related resources
event_grid_count=$(jq '.summary.event_grid_count' <<< "$related_data")
if [[ "$event_grid_count" -gt 0 ]]; then
  event_grid_names=$(jq -r '.event_grid_subscriptions[].name' <<< "$related_data" | jq -Rs '. | rtrimstr("\n") | split("\n") | join(", ")')
  add_issue 4 \
    "$event_grid_count Event Grid subscription(s) found using Service Bus namespace $SB_NAMESPACE_NAME" \
    "Ensure these Event Grid subscriptions are properly configured and monitored" \
    "Event Grid subscriptions: $event_grid_names"
fi

# Map out potential app dependencies
logic_app_count=$(jq '.summary.logic_app_count' <<< "$related_data")
web_app_count=$(jq '.summary.web_app_count' <<< "$related_data")
function_app_count=$(jq '.summary.function_app_count' <<< "$related_data")

total_app_count=$((logic_app_count + web_app_count + function_app_count))
if [[ "$total_app_count" -gt 0 ]]; then
  app_names=""
  
  if [[ "$logic_app_count" -gt 0 ]]; then
    logic_app_names=$(jq -r '.logic_apps[].name' <<< "$related_data" | jq -Rs '. | rtrimstr("\n") | split("\n") | join(", ")')
    app_names+="Logic Apps: $logic_app_names"
  fi
  
  if [[ "$web_app_count" -gt 0 ]]; then
    web_app_names=$(jq -r '.web_apps[].name' <<< "$related_data" | jq -Rs '. | rtrimstr("\n") | split("\n") | join(", ")')
    [[ -n "$app_names" ]] && app_names+=", "
    app_names+="Web Apps: $web_app_names"
  fi
  
  if [[ "$function_app_count" -gt 0 ]]; then
    function_app_names=$(jq -r '.function_apps[].name' <<< "$related_data" | jq -Rs '. | rtrimstr("\n") | split("\n") | join(", ")')
    [[ -n "$app_names" ]] && app_names+=", "
    app_names+="Function Apps: $function_app_names"
  fi
  
  add_issue 4 \
    "$total_app_count application(s) potentially using Service Bus namespace $SB_NAMESPACE_NAME" \
    "Ensure these applications have proper retry policies and connection string management" \
    "Applications: $app_names"
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 