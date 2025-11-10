#!/bin/bash

RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}

ISSUES_FILE="repository_events_issues.json"
echo '[]' > "$ISSUES_FILE"

add_issue() {
  local title="$1"
  local severity="$2"
  local expected="$3"
  local actual="$4"
  local details="$5"
  local next_steps="$6"
  local observed_at="${7:-$(date '+%Y-%m-%d %H:%M:%S')}"
  details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  next_steps=$(echo "$next_steps" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  local issue="{\"title\":\"$title\",\"severity\":$severity,\"expected\":\"$expected\",\"actual\":\"$actual\",\"details\":\"$details\",\"next_steps\":\"$next_steps\",\"observed_at\":\"$observed_at\"}"
  jq ". += [${issue}]" "$ISSUES_FILE" > temp.json && mv temp.json "$ISSUES_FILE"
}

# Get ACR resource ID for discovering Log Analytics workspace
if [ -n "$SUBSCRIPTION_ID" ] && [ -n "$RESOURCE_GROUP" ] && [ -n "$ACR_NAME" ]; then
  acr_resource_id=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null)
  
  # Discover Log Analytics workspace
  echo "🔍 Discovering Log Analytics workspace for ACR..." >&2
  diagnostic_settings=$(az monitor diagnostic-settings list --resource "$acr_resource_id" -o json 2>/dev/null)
  
  LOG_WORKSPACE_ID=""
  if [ -n "$diagnostic_settings" ] && [ "$diagnostic_settings" != "[]" ]; then
    LOG_WORKSPACE_ID=$(echo "$diagnostic_settings" | jq -r '.[].workspaceId // empty' | head -1)
  fi
  
  # Fallback: search for workspace in resource group
  if [ -z "$LOG_WORKSPACE_ID" ]; then
    workspaces=$(az monitor log-analytics workspace list --resource-group "$RESOURCE_GROUP" -o json 2>/dev/null)
    if [ -n "$workspaces" ] && [ "$workspaces" != "[]" ]; then
      LOG_WORKSPACE_ID=$(echo "$workspaces" | jq -r '.[0].id')
    fi
  fi
fi

if [ -z "$LOG_WORKSPACE_ID" ]; then
  add_issue "Log Analytics workspace not found" 4 "Log Analytics workspace should be configured for ACR monitoring" "No Log Analytics workspace discovered" "Cannot query repository events without workspace" "Configure Log Analytics workspace for ACR \`$ACR_NAME\` by setting up diagnostic settings in resource group \`$RESOURCE_GROUP\`"
  cat "$ISSUES_FILE"
  exit 0
fi

echo "📊 Using Log Analytics workspace: $LOG_WORKSPACE_ID" >&2

# First, check if the ContainerRegistryRepositoryEvents table exists
table_check_query="ContainerRegistryRepositoryEvents | take 1"
table_check_result=$(az monitor log-analytics query --workspace "$LOG_WORKSPACE_ID" --analytics-query "$table_check_query" 2>table_check_error.log)
table_check_exit_code=$?

if [ $table_check_exit_code -ne 0 ]; then
  table_error=$(cat table_check_error.log 2>/dev/null || echo "Unknown error occurred")
  
  # Check if it's a PathNotFoundError (table doesn't exist)
  if echo "$table_error" | grep -q "PathNotFoundError\|does not exist"; then
    add_issue "ContainerRegistryRepositoryEvents table not found in Log Analytics" 4 "ACR diagnostic logs should be configured to send events to Log Analytics" "ContainerRegistryRepositoryEvents table does not exist in the workspace" "Log Analytics workspace: $LOG_WORKSPACE_ID
ACR: $ACR_NAME
Resource Group: $RESOURCE_GROUP
Error: $table_error

This indicates that either:
1. Diagnostic settings are not configured for the ACR
2. No ACR events have been generated yet
3. The diagnostic logs category 'ContainerRegistryRepositoryEvents' is not enabled" "Configure diagnostic settings for ACR \`$ACR_NAME\` to send ContainerRegistryRepositoryEvents logs to the Log Analytics workspace. This will enable monitoring of pull/push operations and failures." "az monitor diagnostic-settings create --resource \$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query id -o tsv) --workspace $LOG_WORKSPACE_ID --logs '[{\"category\":\"ContainerRegistryRepositoryEvents\",\"enabled\":true}]' --name acr-diagnostics"
  else
    add_issue "Failed to access Log Analytics workspace" 4 "Should be able to query Log Analytics workspace" "Cannot access ContainerRegistryRepositoryEvents table" "Log Analytics workspace: $LOG_WORKSPACE_ID
Error: $table_error" "Check permissions to Log Analytics workspace and verify the workspace ID is correct for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`" "az monitor log-analytics workspace show --workspace-name \$(basename $LOG_WORKSPACE_ID) --resource-group $RESOURCE_GROUP"
  fi
  rm -f table_check_error.log
  cat "$ISSUES_FILE"
  exit 0
fi

# If table exists, proceed with the actual query
query_result=$(az monitor log-analytics query --workspace "$LOG_WORKSPACE_ID" --analytics-query "ContainerRegistryRepositoryEvents | where ResultType != 0 | summarize count() by ResultType, bin(TimeGenerated, 5m) | top 5 by count_" 2>query_error.log)

if [ $? -ne 0 ]; then
  error_details=$(cat query_error.log 2>/dev/null || echo "Unknown error occurred")
  add_issue "Failed to query repository events" 4 "Should be able to query repository events" "Command failed" "Query error: $error_details" "Check permissions and workspace configuration for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`. Verify Log Analytics workspace access and that diagnostic settings are configured to send ACR events to the workspace."
  rm -f query_error.log
fi

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE"
