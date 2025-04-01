#!/bin/bash

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
# Set expiration threshold in days (e.g., 30 days)
threshold_days="$THRESHOLD_DAYS"

# Get current date in Unix timestamp format
CURRENT_DATE=$(date +%s)

# Get a list of all Key Vaults in the subscription
keyvaults=$(az keyvault list -g "$resource_group" --subscription "$subscription_id" --query "[].{id:id,name:name, resourceGroup:resourceGroup}" -o json)

# Initialize an empty JSON array
result="[]"

# Loop through each Key Vault
for row in $(echo "${keyvaults}" | jq -c '.[]'); do
    name=$(echo $row | jq -r '.name')
    resourceGroup=$(echo $row | jq -r '.resourceGroup')
    resource_id=$(echo $row | jq -r '.id')
    resource_url="https://portal.azure.com/#@/resource${resource_id}"

    # ------------------------
    # Check Expiring Secrets
    # ------------------------
    secrets=$(az keyvault secret list --vault-name "$name" --query "[].{id:id, name:name}" -o json)
    for secret in $(echo "${secrets}" | jq -c '.[]'); do
        secretName=$(echo $secret | jq -r '.name')
        secretId=$(echo $secret | jq -r '.id')
        
        expiryDate=$(az keyvault secret show --id "$secretId" --query "attributes.expires" -o tsv)

        if [[ -n "$expiryDate" && "$expiryDate" != "null" ]]; then
            expiryTimestamp=$(date -d "$expiryDate" +%s)
            remainingDays=$(( (expiryTimestamp - CURRENT_DATE) / 86400 ))

            if [[ $remainingDays -lt 0 || $remainingDays -lt $threshold_days ]]; then
                result=$(echo $result | jq --arg name "$name" --arg resourceGroup "$resourceGroup" --arg type "Secret" --arg item "$secretName" --argjson remainingDays "$remainingDays" --arg resourceUrl "$resource_url/secrets" '. + [{keyVault: $name, resourceGroup: $resourceGroup, type: $type, name: $item, remainingDays: $remainingDays, resourceUrl: $resourceUrl}]')
            fi
        fi
    done

    # ------------------------
    # Check Expiring Certificates
    # ------------------------
    certificates=$(az keyvault certificate list --vault-name "$name" --query "[].{id:id, name:name}" -o json)
    for cert in $(echo "${certificates}" | jq -c '.[]'); do
        certName=$(echo $cert | jq -r '.name')
        certId=$(echo $cert | jq -r '.id')

        expiryDate=$(az keyvault certificate show --id "$certId" --query "attributes.expires" -o tsv)

        if [[ -n "$expiryDate" && "$expiryDate" != "null" ]]; then
            expiryTimestamp=$(date -d "$expiryDate" +%s)
            remainingDays=$(( (expiryTimestamp - CURRENT_DATE) / 86400 ))
            if [[ $remainingDays -lt 0 || $remainingDays -lt $threshold_days ]]; then
                result=$(echo $result | jq --arg name "$name" --arg resourceGroup "$resourceGroup" --arg type "Certificate" --arg item "$certName" --argjson remainingDays "$remainingDays" --arg resourceUrl "$resource_url/certificates" '. + [{keyVault: $name, resourceGroup: $resourceGroup, type: $type, name: $item, remainingDays: $remainingDays, resourceUrl: $resourceUrl}]')
            fi
        fi
    done

    # ------------------------
    # Check Expiring Keys
    # ------------------------
    keys=$(az keyvault key list --vault-name "$name" -o json)
    for key in $(echo "${keys}" | jq -c '.[]'); do
        keyName=$(echo $key | jq -r '.name')
        expiryDate=$(echo $key | jq -r '.attributes.expires')

        if [[ -n "$expiryDate" && "$expiryDate" != "null" ]]; then
            expiryTimestamp=$(date -d "$expiryDate" +%s)
            remainingDays=$(( (expiryTimestamp - CURRENT_DATE) / 86400 ))

            if [[ $remainingDays -lt 0 || $remainingDays -lt $threshold_days ]]; then
                result=$(echo $result | jq --arg name "$name" --arg resourceGroup "$resourceGroup" --arg type "Key" --arg item "$keyName" --argjson remainingDays "$remainingDays" --arg resourceUrl "$resource_url/keys" '. + [{keyVault: $name, resourceGroup: $resourceGroup, type: $type, name: $item, remainingDays: $remainingDays, resourceUrl: $resourceUrl}]')
            fi
        fi
    done
done

# Print JSON result
echo $result
