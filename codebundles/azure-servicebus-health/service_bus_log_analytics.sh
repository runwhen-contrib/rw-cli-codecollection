#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  service_bus_log_analytics.sh
#
#  PURPOSE:
#    Queries Log Analytics for Service Bus related logs and errors
#
#  REQUIRED ENV VARS
#    SB_NAMESPACE_NAME    Name of the Service Bus namespace
#    AZ_RESOURCE_GROUP    Resource group containing the namespace
#
#  OPTIONAL ENV VAR
#    AZURE_RESOURCE_SUBSCRIPTION_ID  Subscription to target (defaults to az login context)
#    QUERY_TIMESPAN                  Time span for log queries (default: P1D - last 24 hours)
#    LOG_ANALYTICS_WORKSPACE         Log Analytics workspace name (optional, will try to auto-detect)
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

LOG_OUTPUT="service_bus_logs.json"
ISSUES_OUTPUT="service_bus_log_issues.json"
QUERY_TIMESPAN="${QUERY_TIMESPAN:-P1D}"
echo "[]" > "$LOG_OUTPUT"
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
# 3) Get Service Bus resource ID and find Log Analytics workspace
# ---------------------------------------------------------------------------
echo "Getting resource ID for Service Bus namespace: $SB_NAMESPACE_NAME"

resource_id=$(az servicebus namespace show \
  --name "$SB_NAMESPACE_NAME" \
  --resource-group "$AZ_RESOURCE_GROUP" \
  --query "id" -o tsv)

echo "Resource ID: $resource_id"

# Try to find Log Analytics workspace
workspace_id=""
if [[ -n "${LOG_ANALYTICS_WORKSPACE:-}" ]]; then
  echo "Using specified Log Analytics workspace: $LOG_ANALYTICS_WORKSPACE"
  workspace_id=$(az monitor log-analytics workspace show \
    --workspace-name "$LOG_ANALYTICS_WORKSPACE" \
    --query "id" -o tsv 2>/dev/null || echo "")
else
  echo "Auto-detecting Log Analytics workspace..."
  # Try to find workspace in the same resource group first
  workspace_id=$(az monitor log-analytics workspace list \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --query "[0].id" -o tsv 2>/dev/null || echo "")
  
  # If not found in same RG, try to find any workspace in the subscription
  if [[ -z "$workspace_id" ]]; then
    workspace_id=$(az monitor log-analytics workspace list \
      --query "[0].id" -o tsv 2>/dev/null || echo "")
  fi
fi

if [[ -z "$workspace_id" ]]; then
  echo "⚠️  No Log Analytics workspace found. Skipping log queries."
  # Create a minimal output indicating no workspace
  jq -n '{operationLogs: [], requestLogs: [], errorLogs: []}' > "$LOG_OUTPUT"
  jq -n --arg ns "$SB_NAMESPACE_NAME" \
    '{namespace:$ns,issues:[{severity:4,title:"No Log Analytics workspace found",next_step:"Configure diagnostic settings to send logs to Log Analytics",details:"No Log Analytics workspace detected"}]}' > "$ISSUES_OUTPUT"
  echo "✅ Analysis complete (no workspace found). Issues written to $ISSUES_OUTPUT"
  exit 0
fi

echo "Using Log Analytics workspace: $workspace_id"

# ---------------------------------------------------------------------------
# 4) Query Log Analytics for Service Bus logs
# ---------------------------------------------------------------------------
echo "Querying logs for Service Bus namespace: $SB_NAMESPACE_NAME (timespan: $QUERY_TIMESPAN)"

# Define Log Analytics queries with shorter timeouts
operation_logs_query="AzureDiagnostics 
| where ResourceId == '$resource_id' 
| where Category == 'OperationalLogs'
| project TimeGenerated, OperationName, Category, Resource, ResourceGroup, status_s, error_s
| order by TimeGenerated desc
| take 100"

request_logs_query="AzureDiagnostics 
| where ResourceId == '$resource_id' 
| where Category == 'RootServiceTracking'
| project TimeGenerated, OperationName, Category, Resource, ResultDescription, ResultType
| order by TimeGenerated desc
| take 100"

error_logs_query="AzureDiagnostics 
| where ResourceId == '$resource_id' 
| where Level == 'Error' or ResultType has 'Failed' or status_s has 'Failed' or error_s != ''
| project TimeGenerated, OperationName, Category, Resource, ResultDescription, ResultType, error_s, status_s
| order by TimeGenerated desc
| take 50"

# Run queries with timeout
echo "Querying operational logs..."
operation_logs=$(timeout 30 az monitor log-analytics query \
  --workspace "$workspace_id" \
  --analytics-query "$operation_logs_query" \
  --timespan "$QUERY_TIMESPAN" \
  -o json 2>/dev/null || echo "[]")

echo "Querying request logs..."
request_logs=$(timeout 30 az monitor log-analytics query \
  --workspace "$workspace_id" \
  --analytics-query "$request_logs_query" \
  --timespan "$QUERY_TIMESPAN" \
  -o json 2>/dev/null || echo "[]")

echo "Querying error logs..."
error_logs=$(timeout 30 az monitor log-analytics query \
  --workspace "$workspace_id" \
  --analytics-query "$error_logs_query" \
  --timespan "$QUERY_TIMESPAN" \
  -o json 2>/dev/null || echo "[]")

# Combine log results
logs_data=$(jq -n \
  --argjson ops "$operation_logs" \
  --argjson req "$request_logs" \
  --argjson err "$error_logs" \
  '{operationLogs: $ops, requestLogs: $req, errorLogs: $err}')

echo "$logs_data" > "$LOG_OUTPUT"
echo "Log data saved to $LOG_OUTPUT"

# ---------------------------------------------------------------------------
# 5) Analyze logs for issues
# ---------------------------------------------------------------------------
echo "Analyzing logs for potential issues..."

issues="[]"
add_issue() {
  local sev="$1" title="$2" next="$3" details="$4"
  issues=$(jq --arg s "$sev" --arg t "$title" \
              --arg n "$next" --arg d "$details" \
              '. += [{severity:($s|tonumber),title:$t,next_step:$n,details:$d}]' \
              <<<"$issues")
}

# Check for error logs
error_count=$(jq '.errorLogs | length' <<< "$logs_data")
if [[ "$error_count" -gt 0 ]]; then
  # Get the most recent errors (up to 5)
  recent_errors=$(jq '.errorLogs[0:5]' <<< "$logs_data")
  
  add_issue 1 \
    "Service Bus namespace $SB_NAMESPACE_NAME has $error_count errors in logs" \
    "Investigate the error logs in Log Analytics and address the root causes" \
    "Recent errors: $(echo "$recent_errors" | jq -c)"
fi

# Check for failed operations
failed_ops_count=$(jq '.operationLogs[] | select(.status_s == "Failed") | length' <<< "$logs_data" 2>/dev/null || echo "0")

if [[ "$failed_ops_count" -gt 0 ]]; then
  # Get the most recent failed operations (up to 5)
  recent_failed_ops=$(jq '.operationLogs[] | select(.status_s == "Failed") | .[0:5]' <<< "$logs_data")
  
  add_issue 3 \
    "Service Bus namespace $SB_NAMESPACE_NAME has $failed_ops_count failed operations" \
    "Review the failed operations and investigate the root causes" \
    "Failed operations detected"
fi

# Check if Log Analytics isn't set up properly
if [[ "$error_count" -eq 0 && "$failed_ops_count" -eq 0 && $(jq '.operationLogs | length' <<< "$logs_data") -eq 0 ]]; then
  add_issue 4 \
    "No logs found for Service Bus namespace $SB_NAMESPACE_NAME" \
    "Verify that diagnostic settings are configured to send logs to Log Analytics" \
    "No logs detected in Log Analytics"
fi

# Write issues to output file
jq -n --arg ns "$SB_NAMESPACE_NAME" --argjson issues "$issues" \
      '{namespace:$ns,issues:$issues}' > "$ISSUES_OUTPUT"

echo "✅ Analysis complete. Issues written to $ISSUES_OUTPUT" 