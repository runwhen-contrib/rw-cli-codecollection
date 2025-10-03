#!/bin/bash

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

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-}"
ACR_NAME="${ACR_NAME:-}"

ISSUES_FILE="login_issues.json"
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

if [ -z "$SUBSCRIPTION_ID" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$ACR_NAME" ]; then
  missing_vars=()
  [ -z "$SUBSCRIPTION_ID" ] && missing_vars+=("AZURE_SUBSCRIPTION_ID")
  [ -z "$RESOURCE_GROUP" ] && missing_vars+=("AZ_RESOURCE_GROUP")
  [ -z "$ACR_NAME" ] && missing_vars+=("ACR_NAME")
  echo "Missing required environment variables: ${missing_vars[*]}" >&2
  add_issue \
    "Missing required environment variables" \
    4 \
    "All required environment variables should be set" \
    "Missing variables: ${missing_vars[*]}" \
    "Required variables: AZURE_SUBSCRIPTION_ID, AZ_RESOURCE_GROUP, ACR_NAME" \
    "Set the missing environment variables and retry"
  cat "$ISSUES_FILE"
  exit 0
fi

if ! az account show --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  add_issue \
    "Azure authentication failed for subscription $SUBSCRIPTION_ID" \
    4 \
    "Azure CLI should authenticate successfully" \
    "Azure authentication failed for subscription $SUBSCRIPTION_ID" \
    "SUBSCRIPTION_ID: $SUBSCRIPTION_ID" \
    "Check Azure credentials and login with 'az login' or set the correct subscription \`$SUBSCRIPTION_ID\`."
  echo '{"error": "Azure authentication failed"}' >&2
  cat "$ISSUES_FILE"
  exit 0
fi

az account set --subscription "$SUBSCRIPTION_ID"

acr_info=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" -o json 2>az_acr_show_err.log)
if [ $? -ne 0 ] || [ -z "$acr_info" ]; then
  # Check for permission error
  if grep -q "AuthorizationFailed" az_acr_show_err.log; then
    add_issue \
      "Insufficient permissions to access ACR '$ACR_NAME' (RG: '$RESOURCE_GROUP')" \
      3 \
      "User/service principal should have 'AcrRegistryReader' or higher role on the registry" \
      "az acr show failed due to insufficient permissions" \
      "See az_acr_show_err.log for details" \
      "Assign 'AcrRegistryReader' or higher role to the user/service principal for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`."
  else
    add_issue \
      "ACR '$ACR_NAME' (RG: '$RESOURCE_GROUP') is unreachable or not found (Subscription: $SUBSCRIPTION_ID)" \
      3 \
      "ACR should be reachable and exist in the specified resource group and subscription" \
      "ACR '$ACR_NAME' is unreachable or not found" \
      "Tried: az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --subscription $SUBSCRIPTION_ID" \
      "Check if ACR \`$ACR_NAME\` exists in resource group \`$RESOURCE_GROUP\`, is spelled correctly, and is accessible from your network."
  fi
  cat "$ISSUES_FILE"
  exit 0
fi

# Retrieve admin credentials
admin_creds=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" -o json 2>az_acr_cred_err.log)
if [ $? -ne 0 ] || [ -z "$admin_creds" ]; then
  if grep -q "AuthorizationFailed" az_acr_cred_err.log; then
    add_issue \
      "Insufficient permissions to retrieve admin credentials for ACR '$ACR_NAME'" \
      3 \
      "User/service principal should have 'AcrRegistryReader' or higher role on the registry" \
      "az acr credential show failed due to insufficient permissions" \
      "See az_acr_cred_err.log for details" \
      "Assign 'AcrRegistryReader' or higher role to the user/service principal for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`."
  else
    add_issue \
      "Failed to retrieve admin credentials for ACR '$ACR_NAME'" \
      3 \
      "Should be able to retrieve admin credentials if admin is enabled" \
      "az acr credential show failed" \
      "Tried: az acr credential show --name $ACR_NAME --resource-group $RESOURCE_GROUP" \
      "Check if admin user is enabled for ACR \`$ACR_NAME\` and you have sufficient permissions in resource group \`$RESOURCE_GROUP\`."
  fi
  cat "$ISSUES_FILE"
  exit 0
fi

login_server=$(echo "$acr_info" | jq -r '.loginServer')
admin_username=$(echo "$admin_creds" | jq -r '.username')
# admin_password=$(echo "$admin_creds" | jq -r '.passwords[0].value')

# Test ACR authentication using token-based approach (Docker CLI not available)
echo "🔐 Testing ACR authentication using token..." >&2
token_result=$(az acr login --name "$ACR_NAME" --expose-token 2>acr_token_error.log)
token_exit_code=$?

if [ $token_exit_code -ne 0 ]; then
  token_error=$(cat acr_token_error.log 2>/dev/null || echo "Unknown error")
  add_issue \
    "ACR token authentication failed" \
    2 \
    "Should be able to authenticate to ACR using Azure credentials" \
    "az acr login --expose-token failed" \
    "Token authentication error: $token_error" \
    "Check Azure authentication and permissions for ACR \`$ACR_NAME\`. Ensure you have AcrPush or AcrPull role in resource group \`$RESOURCE_GROUP\`."
  rm -f acr_token_error.log
  cat "$ISSUES_FILE"
  exit 0
fi

# Verify we got a valid token response
if echo "$token_result" | jq -e '.accessToken' >/dev/null 2>&1; then
  echo "✅ ACR token authentication successful" >&2
  token_length=$(echo "$token_result" | jq -r '.accessToken' | wc -c)
  echo "   Token received (length: $token_length characters)" >&2
else
  add_issue \
    "ACR token response invalid" \
    2 \
    "Should receive valid access token from ACR" \
    "Token response does not contain valid accessToken" \
    "Token response: $token_result" \
    "Check ACR \`$ACR_NAME\` configuration and Azure authentication in resource group \`$RESOURCE_GROUP\`."
  cat "$ISSUES_FILE"
  exit 0
fi

rm -f acr_token_error.log

# If everything succeeded
rm -f az_acr_show_err.log az_acr_cred_err.log acr_token_error.log

echo '{"status": "reachable"}' >&2
echo '[]' > "$ISSUES_FILE"

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE" 