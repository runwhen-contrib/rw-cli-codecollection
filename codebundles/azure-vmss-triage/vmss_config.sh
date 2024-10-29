#!/bin/bash

# ENV:
# AZ_USERNAME
# AZ_SECRET_VALUE
# AZ_SUBSCRIPTION
# AZ_TENANT
# VMSCALESET
# AZ_RESOURCE_GROUP

# # Log in to Azure CLI
# az login --service-principal --username $AZ_USERNAME --password $AZ_SECRET_VALUE --tenant $AZ_TENANT > /dev/null
# # Set the subscription
# az account set --subscription $AZ_SUBSCRIPTION

az vmss show --name $VMSCALESET --resource-group $AZ_RESOURCE_GROUP

resource_id=$(az vmss show --resource-group $AZ_RESOURCE_GROUP --name $VMSCALESET --query id -o tsv)
echo "Scanning configuration of resource $resource_id"
prowler azure --az-cli-auth --service vm --output-directory /tmp/prowler --output-filename prowler_azure_scan > /dev/null
report_json=$(cat /tmp/prowler/prowler_azure_scan.ocsf.json)
report_csv=$(cat /tmp/prowler/prowler_azure_scan.csv)
report=()
ok=0
for entry in $(echo "$report_json" | jq -r '.[] | @base64'); do
    _jq() {
        echo ${entry} | base64 --decode | jq -r ${1}
    }
    status_code=$(_jq '.status_code')
    if [ "$status_code" != "PASS" ] && [ "$(_jq '.resources[].uid')" == "$resource_id" ]; then
      resource_name=$(_jq '.resources[].uid')
      status_details=$(_jq '.status_details')
      risk_details=$(_jq '.risk_details')
      report+=("--------------------")
      report+=("Resource Name: $resource_name")
      report+=("Status Code: $status_code")
      report+=("Status Details: $status_details")
      report+=("Risk Details: $risk_details")
      report+=(" ")
      report+=(" ")
      ok=1
    fi
done
if [ $ok -eq 0 ]; then
  echo "No issues found in the scan"
else
  echo "Issues found in the scan related to resource $resource_id"
  echo -e "${report[@]}"
fi
exit $ok