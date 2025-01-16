#!/bin/bash

# Variables
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
mkdir -p "$OUTPUT_DIR"
HEALTH_OUTPUT="${OUTPUT_DIR}/backend_pool_members_health.json"
rm -rf $HEALTH_OUTPUT || true
newline=$'\n'

# Ensure required environment variables are set
if [ -z "$APP_GATEWAY_NAME" ] || [ -z "$AZ_RESOURCE_GROUP" ]; then
    echo "Error: APP_GATEWAY_NAME and AZ_RESOURCE_GROUP environment variables must be set."
    exit 1
fi

echo "Checking backend pool members health for Application Gateway $APP_GATEWAY_NAME in resource group $AZ_RESOURCE_GROUP"

# Fetch backend health from Application Gateway
BACKEND_HEALTH=$(az network application-gateway show-backend-health --name "$APP_GATEWAY_NAME" --resource-group "$AZ_RESOURCE_GROUP" -o json)

# Initialize issues JSON
issues_json='{"issues": []}'

# Parse backend health
BACKEND_POOLS=$(echo "$BACKEND_HEALTH" | jq -r '.backendAddressPools[] | @base64')

if [ -z "$BACKEND_POOLS" ]; then
    echo "No backend pools configured."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Backend Pools Configured" \
        --arg nextStep "Add backend pools to route traffic to application instances." \
        --arg severity "1" \
        --arg details "The Application Gateway has no backend pools configured." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
else
    for pool_data in $BACKEND_POOLS; do
        pool_name=$(echo "$pool_data" | base64 --decode | jq -r '.backendAddressPool.id')
        echo "Checking health for backend pool: $pool_name"

        http_settings=$(echo "$pool_data" | base64 --decode | jq -r '.backendHttpSettingsCollection[] | @base64')
        for setting_data in $http_settings; do
            servers=$(echo "$setting_data" | base64 --decode | jq -r '.servers[] | @base64')
            for server_data in $servers; do
                address=$(echo "$server_data" | base64 --decode | jq -r '.address')
                health=$(echo "$server_data" | base64 --decode | jq -r '.health')
                log=$(echo "$server_data" | base64 --decode | jq -r '.healthProbeLog')

                if [ "$health" != "Healthy" ]; then
                    # Identify the resource type and fetch details
                    if [[ "$address" == *.azurewebsites.net ]]; then
                        resource_type="App Service"
                        app_service_name=$(echo "$address" | sed 's/.azurewebsites.net//')
                        app_service_details=$(az webapp list --query "[?defaultHostName=='$address'] | [0]" -o json)
                        resource_id=$(echo "$app_service_details" | jq -r '.id')
                        resource_group=$(echo "$app_service_details" | jq -r '.resourceGroup')
                        portal_url="https://portal.azure.com/#@/resource$resource_id/appServices"
                        next_step="Check App Service \`$app_service_name\` Health Check Metrics In Resource Group \`$resource_group\`${newline}View the App Service \`$app_service_name\` in the (Azure Portal)[$portal_url]"
                    elif [[ "$address" == *.azurecontainer.io ]]; then
                        resource_type="Container Instance"
                        resource_id=$(az container list --query "[?contains(ipAddress.fqdn, '$address')].id" -o tsv)
                        portal_url="https://portal.azure.com/#@resource$resource_id"
                        next_step="Inspect the Azure Container Instance logs and events for '$address' in the Azure Portal: $portal_url"
                    elif [[ "$address" == *.hcp.*.azmk8s.io ]]; then
                        resource_type="AKS Cluster"
                        resource_id=$(az aks list --query "[?contains(fqdn, '$address')].id" -o tsv)
                        portal_url="https://portal.azure.com/#@resource$resource_id"
                        next_step="Check the health of the AKS Cluster hosting '$address' in the Azure Portal: $portal_url"
                    elif [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        resource_type="Virtual Machine"
                        resource_id=$(az vm list-ip-addresses --query "[?ipAddress=='$address'].virtualMachine.id" -o tsv)
                        portal_url="https://portal.azure.com/#@resource$resource_id"
                        next_step="Check the health and connectivity of the Virtual Machine at '$address' in the Azure Portal: $portal_url"
                    else
                        resource_type="Unknown Resource"
                        next_step="Investigate the backend resource configuration for '$address' and ensure it responds to health probes."
                    fi

                    issues_json=$(echo "$issues_json" | jq -n \
                        --arg title "Unhealthy $resource_type" \
                        --arg nextStep "$next_step" \
                        --arg severity "2" \
                        --arg details "$log" \
                        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]')
                    echo "Issue Detected: $address is $health ($resource_type)."
                else
                    echo "Member $address is healthy."
                fi
            done
        done
    done
fi

# Save results
echo "$issues_json" > "$HEALTH_OUTPUT"
echo "Backend pool members health check completed. Results saved to $HEALTH_OUTPUT"
