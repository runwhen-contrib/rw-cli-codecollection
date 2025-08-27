#!/bin/bash

set -x
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}
USAGE_THRESHOLD=${USAGE_THRESHOLD:-80}

ISSUES_FILE="storage_usage_issues.json"
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

usage=$(az acr show-usage --name "$ACR_NAME" --subscription "$SUBSCRIPTION_ID" -o json 2>usage_err.log)
if [ $? -ne 0 ]; then
  add_issue "Failed to get storage usage" 4 "Registry storage usage info should be retrievable" "Command failed" "See usage_err.log" "Check if ACR `$ACR_NAME` and subscription `$SUBSCRIPTION_ID` exist and you have access in resource group `$RESOURCE_GROUP`"
else
  used=$(echo "$usage" | jq -r '.value[] | select(.name.value=="StorageUsed") | .currentValue')
  quota=$(echo "$usage" | jq -r '.value[] | select(.name.value=="StorageUsed") | .limitValue')
  percent=$(echo "scale=2; ($used/$quota)*100" | bc)
  if (( $(echo "$percent > $USAGE_THRESHOLD" | bc -l) )); then
    add_issue "High storage usage" 3 "Usage below 80%" "Usage at $percent%" "Consider cleaning images in ACR `$ACR_NAME` or increase quota for resource group `$RESOURCE_GROUP`"
  fi
fi
