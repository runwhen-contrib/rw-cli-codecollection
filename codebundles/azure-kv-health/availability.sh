#!/bin/bash

subscription_id="$AZURE_SUBSCRIPTION_ID"
resource_group="$AZURE_RESOURCE_GROUP"

json_output='{"metrics":['
first=true

for kv in $(az keyvault list -g "$resource_group" --subscription "$subscription_id" --query "[].name" -o tsv); do
  
  availability=$(az monitor metrics list \
    --resource "/subscriptions/$subscription_id/resourceGroups/$resource_group/providers/Microsoft.KeyVault/vaults/$kv" \
    --metric Availability \
    --aggregation average \
    --interval PT1H \
    --query "value[0].timeseries[0].data[-1].average" \
    --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
    --output tsv)
  
  # Default to N/A if no data is returned
  availability=${availability:-"N/A"}

  # Append to JSON array
  if [ "$first" = true ]; then
    first=false
  else
    json_output+=','
  fi
  json_output+="{\"kv_name\":\"$kv\",\"percentage\":\"$availability\"}"
done

json_output+=']}'
echo "$json_output"