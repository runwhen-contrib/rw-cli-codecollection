#!/bin/bash


# Check if AKS cluster exists
if ! az aks show --resource-group "$AZ_RESOURCE_GROUP" --name "$AKS_CLUSTER" > /dev/null 2>&1; then
  echo "AKS cluster $AKS_CLUSTER not found in resource group $AZ_RESOURCE_GROUP."
  exit 1
fi

# Fetch resource ID and initiate scan
resource_id=$(az aks show --resource-group "$AZ_RESOURCE_GROUP" --name "$AKS_CLUSTER" --query id -o tsv)
echo "Scanning configuration of resource $resource_id"

# Run Prowler scan with error handling
# if ! prowler azure --az-cli-auth --service aks --output-directory /tmp/prowler --output-filename prowler_azure_scan > /dev/null 2>&1; then
#   echo "Prowler scan failed. Please check the configuration and try again."
#   exit 1
# fi

prowler azure --az-cli-auth --service aks --compliance cis_2.0_azure --output-directory /tmp/prowler --output-filename prowler_azure_scan

# Check if the expected output files were created
json_file="/tmp/prowler/prowler_azure_scan.ocsf.json"
csv_file="/tmp/prowler/prowler_azure_scan.csv"

if [ ! -f "$json_file" ] || [ ! -f "$csv_file" ]; then
  echo "Prowler scan output files not found. Scan may have failed."
  exit 1
fi

# Parse the JSON report and gather failed entries
report=()
ok=0
report_json=$(cat "$json_file")

for entry in $(echo "$report_json" | jq -r '.[] | @base64'); do
  _jq() {
    echo "${entry}" | base64 --decode | jq -r "${1}"
  }
  status_code=$(_jq '.status_code')
  resource_uid=$(_jq '.resources[].uid')

  # Only process entries that failed and match the AKS resource ID
  if [ "$status_code" != "PASS" ] && [ "$resource_uid" == "$resource_id" ]; then
    report+=("Resource Name: $resource_uid")
    report+=("Status Code: $status_code")
    report+=("Status Details: $(_jq '.status_details')")
    report+=("Risk Details: $(_jq '.risk_details')")
    report+=("--------------------")
    ok=1
  fi
done

# Output scan results
if [ $ok -eq 0 ]; then
  echo "No issues found in the scan for resource $resource_id."
else
  echo "Issues found in the scan for resource $resource_id:"
  printf "%s\n" "${report[@]}"
fi

exit $ok
