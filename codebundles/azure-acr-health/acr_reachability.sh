#!/bin/bash
# Check Azure Container Registry reachability and next steps

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${AZ_RESOURCE_GROUP:-}"
ACR_NAME="${ACR_NAME:-}"

ISSUES_FILE="reachability_issues.json"
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
  echo "Missing required environment variables: ${missing_vars[*]}"
  echo '{"error": "Required environment variables not set"}'
  exit 1
fi

if ! az account show --subscription "$SUBSCRIPTION_ID" >/dev/null 2>&1; then
  add_issue \
    "Azure authentication failed for subscription $SUBSCRIPTION_ID" \
    4 \
    "Azure CLI should authenticate successfully" \
    "Azure authentication failed for subscription $SUBSCRIPTION_ID" \
    "SUBSCRIPTION_ID: $SUBSCRIPTION_ID" \
    "Check Azure credentials and login with 'az login' or set the correct subscription."
  echo '{"error": "Azure authentication failed"}'
  exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"

acr_info=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" -o json 2>az_acr_show_err.log)
if [ $? -ne 0 ] || [ -z "$acr_info" ]; then
  # Check for permission error
  if grep -q "AuthorizationFailed" az_acr_show_err.log; then
    add_issue \
      "Insufficient permissions to access ACR '$ACR_NAME' (RG: '$RESOURCE_GROUP')" \
      4 \
      "User/service principal should have 'AcrRegistryReader' or higher role on the registry" \
      "az acr show failed due to insufficient permissions" \
      "See az_acr_show_err.log for details" \
      "Assign 'AcrRegistryReader' or higher role to the user/service principal for the registry."
  else
    add_issue \
      "ACR '$ACR_NAME' (RG: '$RESOURCE_GROUP') is unreachable or not found (Subscription: $SUBSCRIPTION_ID)" \
      4 \
      "ACR should be reachable and exist in the specified resource group and subscription" \
      "ACR '$ACR_NAME' is unreachable or not found" \
      "Tried: az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --subscription $SUBSCRIPTION_ID" \
      "Check if the registry exists, is spelled correctly, and is accessible from your network."
  fi
  echo '{"status": "unreachable"}'
  exit 0
fi

# Retrieve admin credentials
admin_creds=$(az acr credential show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" -o json 2>az_acr_cred_err.log)
if [ $? -ne 0 ] || [ -z "$admin_creds" ]; then
  if grep -q "AuthorizationFailed" az_acr_cred_err.log; then
    add_issue \
      "Insufficient permissions to retrieve admin credentials for ACR '$ACR_NAME'" \
      4 \
      "User/service principal should have 'AcrRegistryReader' or higher role on the registry" \
      "az acr credential show failed due to insufficient permissions" \
      "See az_acr_cred_err.log for details" \
      "Assign 'AcrRegistryReader' or higher role to the user/service principal for the registry."
  else
    add_issue \
      "Failed to retrieve admin credentials for ACR '$ACR_NAME'" \
      4 \
      "Should be able to retrieve admin credentials if admin is enabled" \
      "az acr credential show failed" \
      "Tried: az acr credential show --name $ACR_NAME --resource-group $RESOURCE_GROUP" \
      "Check if admin user is enabled and you have sufficient permissions."
  fi
  echo '{"status": "no_admin_creds"}'
  exit 0
fi

login_server=$(echo "$acr_info" | jq -r '.loginServer')
admin_username=$(echo "$admin_creds" | jq -r '.username')
admin_password=$(echo "$admin_creds" | jq -r '.passwords[0].value')

# Attempt docker login
if ! echo "$admin_password" | docker login "$login_server" -u "$admin_username" --password-stdin >docker_login.log 2>&1; then
  add_issue \
    "Docker login to ACR '$ACR_NAME' failed" \
    4 \
    "Should be able to login to the registry using admin credentials" \
    "docker login failed" \
    "See docker_login.log for details" \
    "Check if admin user is enabled, credentials are correct, and Docker is running."
  echo '{"status": "docker_login_failed"}'
  exit 0
fi

# If everything succeeded
rm -f az_acr_show_err.log az_acr_cred_err.log docker_login.log

echo '{"status": "reachable"}'
echo '[]' > "$ISSUES_FILE" 