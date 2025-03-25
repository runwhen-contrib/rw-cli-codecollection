#!/bin/bash

# Set expiration threshold in days (e.g., 30 days)
THRESHOLD_DAYS=30

# Get current date in Unix timestamp format
CURRENT_DATE=$(date +%s)

# Get a list of all Key Vaults in the subscription
keyvaults=$(az keyvault list --query "[].{name:name, resourceGroup:resourceGroup}" -o json)

# Initialize an empty JSON array
result="[]"

# Loop through each Key Vault
for row in $(echo "${keyvaults}" | jq -c '.[]'); do
    name=$(echo $row | jq -r '.name')
    resourceGroup=$(echo $row | jq -r '.resourceGroup')

    echo "Checking Key Vault: $name in Resource Group: $resourceGroup..."

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

            if [[ $remainingDays -lt 0 || $remainingDays -lt $THRESHOLD_DAYS ]]; then
                result=$(echo $result | jq --arg name "$name" --arg resourceGroup "$resourceGroup" --arg type "Secret" --arg item "$secretName" --argjson remainingDays "$remainingDays" '. + [{keyVault: $name, resourceGroup: $resourceGroup, type: $type, name: $item, remainingDays: $remainingDays}]')
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

            if [[ $remainingDays -lt 0 || $remainingDays -lt $THRESHOLD_DAYS ]]; then
                result=$(echo $result | jq --arg name "$name" --arg resourceGroup "$resourceGroup" --arg type "Certificate" --arg item "$certName" --argjson remainingDays "$remainingDays" '. + [{keyVault: $name, resourceGroup: $resourceGroup, type: $type, name: $item, remainingDays: $remainingDays}]')
            fi
        fi
    done

    # ------------------------
    # Check Expiring Keys
    # ------------------------
    keys=$(az keyvault key list --vault-name "$name" --query "[].{id:id, name:name}" -o json)
    for key in $(echo "${keys}" | jq -c '.[]'); do
        keyName=$(echo $key | jq -r '.name')
        keyId=$(echo $key | jq -r '.id')

        expiryDate=$(az keyvault key show --id "$keyId" --query "attributes.expires" -o tsv)

        if [[ -n "$expiryDate" && "$expiryDate" != "null" ]]; then
            expiryTimestamp=$(date -d "$expiryDate" +%s)
            remainingDays=$(( (expiryTimestamp - CURRENT_DATE) / 86400 ))

            if [[ $remainingDays -lt 0 || $remainingDays -lt $THRESHOLD_DAYS ]]; then
                result=$(echo $result | jq --arg name "$name" --arg resourceGroup "$resourceGroup" --arg type "Key" --arg item "$keyName" --argjson remainingDays "$remainingDays" '. + [{keyVault: $name, resourceGroup: $resourceGroup, type: $type, name: $item, remainingDays: $remainingDays}]')
            fi
        fi
    done
done

# Print JSON result
echo $result
