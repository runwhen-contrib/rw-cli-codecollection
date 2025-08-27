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
  details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  next_steps=$(echo "$next_steps" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
  local issue="{\"title\":\"$title\",\"severity\":$severity,\"expected\":\"$expected\",\"actual\":\"$actual\",\"details\":\"$details\",\"next_steps\":\"$next_steps\"}"
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

query_result=$(az monitor log-analytics query --workspace "$LOG_WORKSPACE_ID" --analytics-query "ContainerRegistryRepositoryEvents | where ResultType != 0 | summarize count() by ResultType, bin(TimeGenerated, 5m) | top 5 by count_" 2>/dev/null)

if [ $? -ne 0 ]; then
  add_issue "Failed to query repository events" 4 "Should be able to query repository events" "Command failed" "See CLI errors" "Check permissions and workspace configuration for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`"
fi

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE"
