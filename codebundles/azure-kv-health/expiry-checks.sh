#!/bin/bash
set -euo pipefail

: "${AZURE_SUBSCRIPTION_ID:?Must set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?Must set AZURE_RESOURCE_GROUP}"
: "${THRESHOLD_DAYS:?Must set THRESHOLD_DAYS}"
: "${AZURE_SUBSCRIPTION_NAME:?Must set AZURE_SUBSCRIPTION_NAME}"

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"
threshold_days="$THRESHOLD_DAYS"

OUTPUT_FILE="kv_expiry_issues.json"
issues_json='{"issues": []}'

CURRENT_DATE=$(date +%s)

echo "Checking for expiring Key Vault items..."
echo "Subscription ID: $AZURE_SUBSCRIPTION_ID"
echo "Resource Group:  $AZURE_RESOURCE_GROUP"
echo "Threshold Days:  $THRESHOLD_DAYS"

# Get list of Key Vaults
echo "Retrieving Key Vaults in resource group..."
if ! keyvaults=$(az keyvault list -g "$resource_group" --subscription "$subscription_id" --query "[].{id:id,name:name, resourceGroup:resourceGroup}" -o json 2>kv_list_err.log); then
    err_msg=$(cat kv_list_err.log)
    rm -f kv_list_err.log
    
    echo "ERROR: Could not list Key Vaults."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Key Vaults" \
        --arg details "$err_msg" \
        --arg severity "3" \
        --arg nextStep "Check if the resource group exists and you have the right CLI permissions." \
        '.issues += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
         }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f kv_list_err.log

# Process each Key Vault
for row in $(echo "${keyvaults}" | jq -c '.[]'); do
    name=$(echo $row | jq -r '.name')
    resourceGroup=$(echo $row | jq -r '.resourceGroup')
    resource_id=$(echo $row | jq -r '.id')
    resource_url="https://portal.azure.com/#@/resource${resource_id}"

    # Check Expiring Secrets
    if ! secrets=$(az keyvault secret list --vault-name "$name" -o json 2>secrets_err.log); then
        err_msg=$(cat secrets_err.log)
        rm -f secrets_err.log
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to List Secrets in Key Vault $name" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Check if you have Reader or higher role on the Key Vault resource." \
            --arg name "$name" \
            '.issues += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber),
               "name": $name
             }]')
        continue
    fi
    rm -f secrets_err.log

    for secret in $(echo "${secrets}" | jq -c '.[]'); do
        secretName=$(echo $secret | jq -r '.name')
        secretId=$(echo $secret | jq -r '.id')
        
        if ! expiryDate=$(az keyvault secret show --id "$secretId" --query "attributes.expires" -o tsv 2>secret_expiry_err.log); then
            err_msg=$(cat secret_expiry_err.log)
            rm -f secret_expiry_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed to Get Secret Expiry for $secretName in Key Vault $name" \
                --arg details "$err_msg" \
                --arg severity "3" \
                --arg nextStep "Check if you have Reader or higher role on the Key Vault resource." \
                --arg name "$name" \
                --arg secretName "$secretName" \
                '.issues += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber),
                   "name": $name,
                   "item": $secretName
                 }]')
            continue
        fi
        rm -f secret_expiry_err.log

        if [[ -n "$expiryDate" && "$expiryDate" != "null" ]]; then
            expiryTimestamp=$(date -d "$expiryDate" +%s)
            remainingDays=$(( (expiryTimestamp - CURRENT_DATE) / 86400 ))
            if [[ $remainingDays -eq 0 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Expired Secret \`$secretName\` found in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`"   \
                    --arg details $secret \
                    --arg severity "3" \
                    --arg nextStep "Rotate secret in Key Vault in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg name "$name" \
                    --arg resource_url "$resource_url/secret" \
                    --arg secretName "$secretName" \
                    --argjson remainingDays "$remainingDays" \
                    '.issues += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "name": $name,
                       "item": $secretName,
                       "resource_url": $resource_url,
                       "remaining_days": $remainingDays
                     }]')

            elif [[ $remainingDays -lt $threshold_days ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Expiring Secret \`$secretName\` found in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg details $secret \
                    --arg severity "3" \
                    --arg nextStep "Rotate secret in Key Vault in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg name "$name" \
                    --arg resource_url "$resource_url/secret" \
                    --arg secretName "$secretName" \
                    --argjson remainingDays "$remainingDays" \
                    '.issues += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "name": $name,
                       "item": $secretName,
                       "resource_url": $resource_url,
                       "remaining_days": $remainingDays
                     }]')
            fi
        fi
    done

    # Check Expiring Certificates
    if ! certificates=$(az keyvault certificate list --vault-name "$name" -o json 2>certs_err.log); then
        err_msg=$(cat certs_err.log)
        rm -f certs_err.log
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to List Certificates in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Check if you have Reader or higher role on the Key Vault resource." \
            --arg name "$name" \
            '.issues += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber),
               "name": $name
             }]')
        continue
    fi
    rm -f certs_err.log

    for cert in $(echo "${certificates}" | jq -c '.[]'); do
        certName=$(echo $cert | jq -r '.name')
        certId=$(echo $cert | jq -r '.id')
        
        if ! expiryDate=$(az keyvault certificate show --id "$certId" --query "attributes.expires" -o tsv 2>cert_expiry_err.log); then
            err_msg=$(cat cert_expiry_err.log)
            rm -f cert_expiry_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed to Get Certificate Expiry for \`$certName\` in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                --arg details "$err_msg" \
                --arg severity "3" \
                --arg nextStep "Check if you have Reader or higher role on the Key Vault resource." \
                --arg name "$name" \
                --arg certName "$certName" \
                '.issues += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber),
                   "name": $name,
                   "item": $certName
                 }]')
            continue
        fi
        rm -f cert_expiry_err.log

        if [[ -n "$expiryDate" && "$expiryDate" != "null" ]]; then
            expiryTimestamp=$(date -d "$expiryDate" +%s)
            remainingDays=$(( (expiryTimestamp - CURRENT_DATE) / 86400 ))

            if [[ $remainingDays -eq 0 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Expired Certificate \`$certName\` found in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg details $certificates \
                    --arg severity "3" \
                    --arg nextStep "Rotate certificate in Key Vault in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg name "$name" \
                    --arg certName "$certName" \
                    --arg resource_url "$resource_url/certificate" \
                    --argjson remainingDays "$remainingDays" \
                    '.issues += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "name": $name,
                       "item": $certName,
                       "resource_url": $resource_url,
                       "remaining_days": $remainingDays
                     }]')
            elif [[ $remainingDays -gt 0 && $remainingDays -le $threshold_days ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Certificate \`$certName\` is expiring in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg details "$certificates" \
                    --arg severity "3" \
                    --arg nextStep "Rotate certificate in Key Vault in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg name "$name" \
                    --arg certName "$certName" \
                    --arg resource_url "$resource_url/certificates" \
                    --argjson remainingDays "$remainingDays" \
                    '.issues += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "name": $name,
                       "item": $certName,
                       "resource_url": $resource_url,
                       "remaining_days": $remainingDays
                     }]')
            fi
        fi
    done

    # ------------------------
    # Check Expiring Keys
    # ------------------------
    if ! keys=$(az keyvault key list --vault-name "$name" -o json 2>keys_err.log); then
        err_msg=$(cat keys_err.log)
        rm -f keys_err.log
        
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed to List Keys in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
            --arg details "$err_msg" \
            --arg severity "3" \
            --arg nextStep "Verify you have Reader or higher role on the Key Vault resource in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`\nCheck Key Vault access policies\nValidate network restrictions if applicable" \
            --arg name "$name" \
            '.issues += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber),
               "name": $name
             }]')
        continue
    fi
    rm -f keys_err.log

    for key in $(echo "${keys}" | jq -c '.[]'); do
        keyName=$(echo $key | jq -r '.name')
        expiryDate=$(echo $key | jq -r '.attributes.expires')

        if [[ -n "$expiryDate" && "$expiryDate" != "null" ]]; then
            expiryTimestamp=$(date -d "$expiryDate" +%s)
            remainingDays=$(( (expiryTimestamp - CURRENT_DATE) / 86400 ))

            if [[ $remainingDays -eq 0 ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Expired Key \`$keyName\` found in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg details "$keys" \
                    --arg severity "3" \
                    --arg nextStep "Rotate key in Key Vault in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg name "$name" \
                    --arg keyName "$keyName" \
                    --arg resource_url "$resource_url/keys" \
                    --argjson remainingDays "$remainingDays" \
                    '.issues += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "name": $name,
                       "item": $keyName,
                       "resource_url": $resource_url,
                       "remaining_days": $remainingDays
                     }]')
            elif [[ $remainingDays -gt 0 && $remainingDays -le $threshold_days ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Key \`$keyName\` is expiring in Key Vault \`$name\` in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg details "$keys" \
                    --arg severity "3" \
                    --arg nextStep "Rotate key in Key Vault in resource group \`${AZURE_RESOURCE_GROUP}\` in subscription \`${AZURE_SUBSCRIPTION_NAME}\`" \
                    --arg name "$name" \
                    --arg keyName "$keyName" \
                    --arg resource_url "$resource_url/keys" \
                    --argjson remainingDays "$remainingDays" \
                    '.issues += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber),
                       "name": $name,
                       "item": $keyName,
                       "resource_url": $resource_url,
                       "remaining_days": $remainingDays
                     }]')
            fi
        fi
    done
done

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Key Vault expiry checks completed. Saved results to $OUTPUT_FILE"