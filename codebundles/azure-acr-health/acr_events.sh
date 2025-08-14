#!/bin/bash

RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}
LOG_WORKSPACE_ID=${LOG_WORKSPACE_ID:-}

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

if [ -z "$LOG_WORKSPACE_ID" ]; then
  add_issue "Log workspace ID missing" 4 "Log Analytics workspace ID should be set" "LOG_WORKSPACE_ID is not set" "No query run" "Provide LOG_WORKSPACE_ID to query repository events"
  exit 1
fi

query_result=$(az monitor log-analytics query --workspace "$LOG_WORKSPACE_ID" --query "ContainerRegistryRepositoryEvents | where ResultType != 0 | summarize count() by ResultType, bin(TimeGenerated, 5m) | top 5 by count_")

if [ $? -ne 0 ]; then
  add_issue "Failed to query repository events" 4 "Should be able to query repository events" "Command failed" "See CLI errors" "Check permissions and workspace ID"
fi
