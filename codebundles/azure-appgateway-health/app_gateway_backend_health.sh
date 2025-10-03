#!/usr/bin/env bash
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

set -o pipefail

# Variables
HEALTH_OUTPUT="backend_pool_members_health.json"
rm -rf "$HEALTH_OUTPUT" || true
newline=$'\n'

# Initialize JSON for issues
issues_json='{"issues": []}'

# Ensure required environment variables are set
if [ -z "$APP_GATEWAY_NAME" ] || [ -z "$AZ_RESOURCE_GROUP" ]; then
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: APP_GATEWAY_NAME and AZ_RESOURCE_GROUP environment variables must be set. (detected at $log_timestamp)"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Missing Environment Variables" \
        --arg details "Either \$APP_GATEWAY_NAME or \$AZ_RESOURCE_GROUP was not set." \
        --arg nextStep "Set both environment variables and re-run the script." \
        --arg severity "1" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]')
    echo "$issues_json" > "$HEALTH_OUTPUT"
    exit 1
fi

echo "Checking backend pool members health for Application Gateway '$APP_GATEWAY_NAME' in resource group '$AZ_RESOURCE_GROUP'..."

# Try fetching backend health from Application Gateway
AZ_CMD="az network application-gateway show-backend-health --name \"$APP_GATEWAY_NAME\" --resource-group \"$AZ_RESOURCE_GROUP\" -o json"
if ! BACKEND_HEALTH=$(eval "$AZ_CMD" 2>app_gateway_backend_health_error.log); then
    # CLI returned a non-zero exit code: possibly auth failure, perms issue, etc.
    # Extract timestamp from log context

    log_timestamp=$(extract_log_timestamp "$0")

    echo "Error: Failed to retrieve backend health from Azure CLI command. (detected at $log_timestamp)"
    error_details=$(cat app_gateway_backend_health_error.log)
    
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Unable to Fetch Application Gateway Backend Health" \
        --arg details "Command: $AZ_CMD${newline}Error: $error_details" \
        --arg nextStep "Check RunSession debug logs to validate Azure CLI authentication, permissions, and network connectivity." \
        --arg severity "3" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]')
    
    rm -f app_gateway_backend_health_error.log
    echo "$issues_json" > "$HEALTH_OUTPUT"
    exit 1
fi
rm -f app_gateway_backend_health_error.log  # Cleanup

# Check if output is valid JSON
if ! echo "$BACKEND_HEALTH" | jq '.' >/dev/null 2>&1; then        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")

    # Extract timestamp from log context


    log_timestamp=$(extract_log_timestamp "$0")


    echo "Error: The returned data is not valid JSON. (detected at $log_timestamp)"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Invalid JSON from CLI" \
        --arg details "The Application Gateway backend health output could not be parsed as JSON." \
        --arg nextStep "Check Azure CLI installation or retry the command manually." \
        --arg severity "1" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]')
    echo "$issues_json" > "$HEALTH_OUTPUT"
    exit 1
fi

# If we reach here, we have valid JSON. Proceed:
# Parse backend health
BACKEND_POOLS=$(echo "$BACKEND_HEALTH" | jq -r '.backendAddressPools[]? | @base64')

if [ -z "$BACKEND_POOLS" ]; then
    echo "No backend pools configured."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Backend Pools Configured (What)" \
        --arg details "The Application Gateway has no backend pools configured." \
        --arg nextStep "Add backend pools to route traffic to application instances" \
        --arg severity "1" \
        '.issues += [{
            "title": $title,
            "details": $details,
            "next_step": $nextStep,
            "severity": ($severity | tonumber)
        }]')
else
    for pool_data in $BACKEND_POOLS; do
        pool=$(echo "$pool_data" | base64 --decode)
        pool_id=$(echo "$pool" | jq -r '.backendAddressPool.id // "UnknownPoolId"')
        # Extract just the pool name from the ARM ID
        pool_name=$(basename "$pool_id")

        echo "Checking health for backend pool: $pool_name"

        # The .backendHttpSettingsCollection[] might not exist if no settings are configured
        BACKEND_SETTINGS=$(echo "$pool" | jq -r '.backendHttpSettingsCollection[]? | @base64')
        if [ -z "$BACKEND_SETTINGS" ]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Empty or Misconfigured Backend Pool (What)" \
                --arg details "The backend pool '$pool_name' has no associated HTTP settings." \
                --arg nextStep "Configure HTTP settings for the backend pool \`$pool_name\`" \
                --arg severity "1" \
                '.issues += [{
                    "title": $title,
                    "details": $details,
                    "next_step": $nextStep,
                    "severity": ($severity | tonumber)
                }]')
            continue
        fi

        for setting_data in $BACKEND_SETTINGS; do
            setting=$(echo "$setting_data" | base64 --decode)
            servers=$(echo "$setting" | jq -r '.servers[]? | @base64')
            
            if [ -z "$servers" ]; then
                continue
            fi

            for server_data in $servers; do
                server=$(echo "$server_data" | base64 --decode)
                address=$(echo "$server" | jq -r '.address')
                health=$(echo "$server" | jq -r '.health // "Unknown"')
                log=$(echo "$server" | jq -r '.healthProbeLog // "No health probe log available."')

                # We'll fill these in dynamically
                resource_type="Unknown Resource"
                resource_group_from_lookup="$AZ_RESOURCE_GROUP"  # fallback
                portal_url=""
                next_step="Investigate why this resource is failing health checks. (Where: logs/Azure Portal)"

                # Identify resource type by address
                if [[ "$address" == *.azurewebsites.net ]]; then
                    resource_type="App Service"
                    app_service_name=$(echo "$address" | sed 's/.azurewebsites.net//')
                    app_service_details=$(az webapp list \
                        --query "[?defaultHostName=='$address'] | [0]" -o json 2>/dev/null)
                    resource_id=$(echo "$app_service_details" | jq -r '.id // empty')
                    resource_group_from_lookup=$(echo "$app_service_details" | jq -r '.resourceGroup // empty')

                    if [ -n "$resource_id" ]; then
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check App Service \`$app_service_name\` Health in Resource Group \`$resource_group_from_lookup\`${newline}Investigate Health Check [logs]($portal_url)"
                    fi

                elif [[ "$address" == *.azurecontainer.io ]]; then
                    resource_type="Azure Container Instance"
                    resource_id=$(az container list \
                        --query "[?contains(ipAddress.fqdn, '$address')].id" -o tsv 2>/dev/null)
                    if [ -n "$resource_id" ]; then
                        resource_group_from_lookup=$(echo "$resource_id" | cut -d'/' -f5)
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Inspect Azure Container Instance logs/events for \`$address\` in Resource Group \`$resource_group_from_lookup\`${newline}View details in the [Azure Portal]($portal_url)"
                    fi

                elif [[ "$address" == *.hcp.*.azmk8s.io ]]; then
                    resource_type="AKS Cluster"
                    resource_id=$(az aks list \
                        --query "[?contains(fqdn, '$address')].id" -o tsv 2>/dev/null)
                    if [ -n "$resource_id" ]; then
                        resource_group_from_lookup=$(echo "$resource_id" | cut -d'/' -f5)
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check the AKS Cluster hosting \`$address\` in Resource Group \`$resource_group_from_lookup\`${newline}(e.g., check Pod logs, cluster health, k8s events) [Portal link]($portal_url)"
                    fi

                elif [[ "$address" == *.blob.core.windows.net ]]; then
                    resource_type="Azure Storage Account"
                    storage_account_name=$(echo "$address" | sed 's/.blob.core.windows.net//')
                    storage_account_details=$(az storage account list \
                        --query "[?primaryEndpoints.blob=='https://$address/'] | [0]" -o json 2>/dev/null)
                    resource_id=$(echo "$storage_account_details" | jq -r '.id // empty')
                    resource_group_from_lookup=$(echo "$storage_account_details" | jq -r '.resourceGroup // empty')

                    if [ -n "$resource_id" ]; then
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check Azure Storage Account \`$storage_account_name\` Health in Resource Group \`$resource_group_from_lookup\`${newline}(e.g., check storage account status, blob service availability, network rules) [Portal link]($portal_url)"
                    fi

                elif [[ "$address" == *.file.core.windows.net ]] || [[ "$address" == *.queue.core.windows.net ]] || [[ "$address" == *.table.core.windows.net ]]; then
                    resource_type="Azure Storage Account"
                    storage_account_name=$(echo "$address" | sed 's/\.\(file\|queue\|table\)\.core\.windows\.net//')
                    storage_account_details=$(az storage account list \
                        --query "[?name=='$storage_account_name'] | [0]" -o json 2>/dev/null)
                    resource_id=$(echo "$storage_account_details" | jq -r '.id // empty')
                    resource_group_from_lookup=$(echo "$storage_account_details" | jq -r '.resourceGroup // empty')

                    if [ -n "$resource_id" ]; then
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check Azure Storage Account \`$storage_account_name\` Health in Resource Group \`$resource_group_from_lookup\`${newline}(e.g., check storage account status, service availability, network rules) [Portal link]($portal_url)"
                    fi

                elif [[ "$address" == *.azure-api.net ]]; then
                    resource_type="Azure API Management"
                    apim_name=$(echo "$address" | sed 's/.azure-api.net//')
                    apim_details=$(az apim list \
                        --query "[?gatewayUrl=='https://$address'] | [0]" -o json 2>/dev/null)
                    resource_id=$(echo "$apim_details" | jq -r '.id // empty')
                    resource_group_from_lookup=$(echo "$apim_details" | jq -r '.resourceGroup // empty')

                    if [ -n "$resource_id" ]; then
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check Azure API Management \`$apim_name\` Health in Resource Group \`$resource_group_from_lookup\`${newline}(e.g., check API status, gateway health, backend services) [Portal link]($portal_url)"
                    fi

                elif [[ "$address" == *.azureedge.net ]]; then
                    resource_type="Azure CDN"
                    cdn_name=$(echo "$address" | sed 's/.azureedge.net//')
                    cdn_details=$(az cdn profile list \
                        --query "[?contains(endpointNames, '$cdn_name')] | [0]" -o json 2>/dev/null)
                    resource_id=$(echo "$cdn_details" | jq -r '.id // empty')
                    resource_group_from_lookup=$(echo "$cdn_details" | jq -r '.resourceGroup // empty')

                    if [ -n "$resource_id" ]; then
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check Azure CDN Profile hosting \`$cdn_name\` in Resource Group \`$resource_group_from_lookup\`${newline}(e.g., check CDN endpoint status, origin health, cache performance) [Portal link]($portal_url)"
                    fi

                elif [[ "$address" == *.database.windows.net ]]; then
                    resource_type="Azure SQL Database"
                    sql_server_name=$(echo "$address" | sed 's/.database.windows.net//')
                    sql_server_details=$(az sql server list \
                        --query "[?fullyQualifiedDomainName=='$address'] | [0]" -o json 2>/dev/null)
                    resource_id=$(echo "$sql_server_details" | jq -r '.id // empty')
                    resource_group_from_lookup=$(echo "$sql_server_details" | jq -r '.resourceGroup // empty')

                    if [ -n "$resource_id" ]; then
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check Azure SQL Server \`$sql_server_name\` Health in Resource Group \`$resource_group_from_lookup\`${newline}(e.g., check database connectivity, firewall rules, performance metrics) [Portal link]($portal_url)"
                    fi

                elif [[ "$address" == *.postgres.database.azure.com ]] || [[ "$address" == *.mysql.database.azure.com ]]; then
                    resource_type="Azure Database"
                    db_server_name=$(echo "$address" | sed 's/\.\(postgres\|mysql\)\.database\.azure\.com//')
                    db_server_details=$(az postgres flexible-server list --query "[?fullyQualifiedDomainName=='$address'] | [0]" -o json 2>/dev/null)
                    if [ -z "$(echo "$db_server_details" | jq -r '.id // empty')" ]; then
                        db_server_details=$(az mysql flexible-server list --query "[?fullyQualifiedDomainName=='$address'] | [0]" -o json 2>/dev/null)
                    fi
                    resource_id=$(echo "$db_server_details" | jq -r '.id // empty')
                    resource_group_from_lookup=$(echo "$db_server_details" | jq -r '.resourceGroup // empty')

                    if [ -n "$resource_id" ]; then
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check Azure Database Server \`$db_server_name\` Health in Resource Group \`$resource_group_from_lookup\`${newline}(e.g., check database connectivity, firewall rules, performance metrics) [Portal link]($portal_url)"
                    fi

                elif [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    resource_type="Virtual Machine / IP-based Pool"
                    resource_id=$(az vm list-ip-addresses \
                        --query "[?ipAddress=='$address'].virtualMachine.id" -o tsv 2>/dev/null)
                    if [ -n "$resource_id" ]; then
                        resource_group_from_lookup=$(echo "$resource_id" | cut -d'/' -f5)
                        portal_url="https://portal.azure.com/#@/resource${resource_id}"
                        next_step="Check the VM with IP \`$address\` in Resource Group \`$resource_group_from_lookup\`${newline}(e.g., VM status, network security groups, extension logs) [Portal link]($portal_url)"
                    fi
                fi

                # If the health is not "Healthy", create an issue
                if [ "$health" != "Healthy" ]; then
                    # Title: "Unhealthy App Service Backend in Resource Group `myRG`"
                    issue_title="Unhealthy $resource_type Backend in Resource Group \`$resource_group_from_lookup\` in Subscription \`${AZURE_SUBSCRIPTION_NAME:-Unknown}\`"
                    issue_details="The backend pool '$pool_name' with address '$address' is failing health checks in Application Gateway \`$APP_GATEWAY_NAME\` in Resource Group \`$AZ_RESOURCE_GROUP\` in Subscription \`${AZURE_SUBSCRIPTION_NAME:-Unknown}\`.${newline}Health Probe Log: $log"
                    issues_json=$(echo "$issues_json" | jq \
                        --arg title "$issue_title" \
                        --arg details "$issue_details" \
                        --arg nextStep "$next_step" \
                        --arg severity "2" \
                        '.issues += [{
                            "title": $title,
                            "details": $details,
                            "next_step": $nextStep,
                            "severity": ($severity | tonumber)
                        }]')

                    echo "Issue Detected: $issue_title (Address: $address)."
                else
                    echo "Member $address is healthy ($resource_type)."
                fi
            done
        done
    done
fi

# Save JSON results
echo "$issues_json" > "$HEALTH_OUTPUT"
echo "Backend pool members health check completed."
