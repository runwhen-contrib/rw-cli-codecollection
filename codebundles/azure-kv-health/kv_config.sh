#!/bin/bash

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"

json_output='{"keyVaults":['
first=true

for kv in $(az keyvault list -g "$resource_group" --subscription "$subscription_id" --query "[].name" -o tsv); do
  
  # Get both properties in single command and parse with jq
  kv_properties=$(az keyvault show --name "$kv" --subscription "$subscription_id"  -o json)
  # echo $kv_properties
  soft_delete=$(echo "$kv_properties" | jq -r '.properties.enableSoftDelete')
  purge_protection=$(echo "$kv_properties" | jq -r '.properties.enablePurgeProtection')
  resource_id=$(echo "$kv_properties" | jq -r '.id')
  
  # Build Azure resource URL using the resource ID
  resource_url="https://portal.azure.com/#@/resource${resource_id}/overview"

  # Convert empty values to "Unknown" for safety
  soft_delete=${soft_delete:-"null"}
  purge_protection=${purge_protection:-"null"}
  resource_url=${resource_url:-"null"}

  # Append to JSON array
  if [ "$first" = true ]; then
    first=false
  else
    json_output+=','
  fi

  json_output+="{\"kv_name\":\"$kv\",\"soft_delete\":\"$soft_delete\",\"purge_protection\":\"$purge_protection\",\"resource_url\":\"$resource_url\"}"
done

json_output+=']}'
echo "$json_output"
