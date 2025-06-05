#!/bin/bash

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Determine the Container Apps Environment name
if [[ -z "$CONTAINER_APP_ENV_NAME" || "$CONTAINER_APP_ENV_NAME" == "" ]]; then
    echo "CONTAINER_APP_ENV_NAME not provided. Attempting to discover from Container App..."
    container_app_data=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json 2>/dev/null)
    
    if [[ -n "$container_app_data" ]]; then
        env_id=$(echo "$container_app_data" | jq -r '.properties.environmentId // ""')
        if [[ -n "$env_id" && "$env_id" != "null" ]]; then
            CONTAINER_APP_ENV_NAME=$(echo "$env_id" | sed 's|.*/||')
            echo "Discovered Container Apps Environment: $CONTAINER_APP_ENV_NAME"
        else
            echo "Could not determine Container Apps Environment from Container App."
            exit 1
        fi
    else
        echo "Could not find Container App $CONTAINER_APP_NAME to determine environment."
        exit 1
    fi
fi

echo "Checking Container Apps Environment health: $CONTAINER_APP_ENV_NAME"

# Get the Container Apps Environment details
env_data=$(az containerapp env show --name "$CONTAINER_APP_ENV_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json)

if [[ -z "$env_data" ]]; then
    echo "Error: Container Apps Environment $CONTAINER_APP_ENV_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

issues_json='{"issues": []}'

# Check provisioning state
provisioning_state=$(echo "$env_data" | jq -r '.properties.provisioningState')
echo "Environment Provisioning State: $provisioning_state"

if [[ "$provisioning_state" != "Succeeded" ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Environment Provisioning Issues" \
        --arg nextStep "Check Container Apps Environment $CONTAINER_APP_ENV_NAME provisioning status and resolve any issues." \
        --arg severity "1" \
        --arg details "Environment provisioning state: $provisioning_state" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check environment type and location
env_type=$(echo "$env_data" | jq -r '.properties.environmentType // "Unknown"')
location=$(echo "$env_data" | jq -r '.location')
echo "Environment Type: $env_type"
echo "Location: $location"

# Check VNET configuration
vnet_config=$(echo "$env_data" | jq '.properties.vnetConfiguration // {}')
vnet_internal=$(echo "$vnet_config" | jq -r '.internal // false')
infrastructure_subnet_id=$(echo "$vnet_config" | jq -r '.infrastructureSubnetId // "not set"')

echo "VNET Configuration:"
echo "  Internal: $vnet_internal"
echo "  Infrastructure Subnet: $infrastructure_subnet_id"

# Check Log Analytics configuration
log_config=$(echo "$env_data" | jq '.properties.appLogsConfiguration // {}')
log_destination=$(echo "$log_config" | jq -r '.destination // "not set"')
workspace_id=$(echo "$log_config" | jq -r '.logAnalyticsConfiguration.customerId // "not set"')

echo "Logging Configuration:"
echo "  Destination: $log_destination"
echo "  Workspace ID: $workspace_id"

if [[ "$log_destination" == "not set" || "$log_destination" == "null" ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Logging Configuration" \
        --arg nextStep "Configure Log Analytics for Container Apps Environment $CONTAINER_APP_ENV_NAME to enable logging and monitoring." \
        --arg severity "3" \
        --arg details "No logging destination configured for the environment" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check Dapr configuration
dapr_config=$(echo "$env_data" | jq '.properties.daprAIInstrumentationKey // {}')
dapr_enabled=$(echo "$env_data" | jq -r '.properties.daprConfiguration.enabled // false')

echo "Dapr Configuration:"
echo "  Dapr Enabled: $dapr_enabled"

# Check zone redundancy (if available)
zone_redundant=$(echo "$env_data" | jq -r '.properties.zoneRedundant // false')
echo "Zone Redundant: $zone_redundant"

# Get Container Apps in this environment
echo "Checking Container Apps in environment..."
container_apps_in_env=$(az containerapp list --resource-group "$AZ_RESOURCE_GROUP" --environment "$CONTAINER_APP_ENV_NAME" --output json 2>/dev/null)

if [[ -n "$container_apps_in_env" ]]; then
    app_count=$(echo "$container_apps_in_env" | jq 'length')
    echo "Container Apps in environment: $app_count"
    
    # Check for unhealthy apps in the environment
    unhealthy_apps=0
    while IFS= read -r app; do
        app_name=$(echo "$app" | jq -r '.name')
        provisioning_state=$(echo "$app" | jq -r '.properties.provisioningState')
        
        if [[ "$provisioning_state" != "Succeeded" ]]; then
            unhealthy_apps=$((unhealthy_apps + 1))
            echo "  Unhealthy app: $app_name (state: $provisioning_state)"
        fi
    done < <(echo "$container_apps_in_env" | jq -c '.[]')
    
    if [[ $unhealthy_apps -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Unhealthy Container Apps in Environment" \
            --arg nextStep "Investigate $unhealthy_apps unhealthy Container Apps in environment $CONTAINER_APP_ENV_NAME." \
            --arg severity "2" \
            --arg details "$unhealthy_apps out of $app_count Container Apps are not in 'Succeeded' state" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
else
    echo "No Container Apps found in environment or failed to query."
fi

# Check environment certificates (if any)
echo "Checking environment certificates..."
certificates=$(az containerapp env certificate list --name "$CONTAINER_APP_ENV_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json 2>/dev/null)

if [[ -n "$certificates" ]]; then
    cert_count=$(echo "$certificates" | jq 'length')
    echo "Certificates configured: $cert_count"
    
    # Check for expiring certificates (within 30 days)
    expiring_certs=0
    current_time=$(date +%s)
    thirty_days_ahead=$((current_time + 30 * 24 * 60 * 60))
    
    while IFS= read -r cert; do
        cert_name=$(echo "$cert" | jq -r '.name')
        expiration_date=$(echo "$cert" | jq -r '.properties.expirationDate')
        
        if [[ "$expiration_date" != "null" ]]; then
            expiration_timestamp=$(date -d "$expiration_date" +%s 2>/dev/null)
            if [[ $? -eq 0 && $expiration_timestamp -lt $thirty_days_ahead ]]; then
                expiring_certs=$((expiring_certs + 1))
                echo "  Expiring certificate: $cert_name (expires: $expiration_date)"
            fi
        fi
    done < <(echo "$certificates" | jq -c '.[]')
    
    if [[ $expiring_certs -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Expiring Certificates" \
            --arg nextStep "Renew $expiring_certs certificate(s) expiring within 30 days in environment $CONTAINER_APP_ENV_NAME." \
            --arg severity "3" \
            --arg details "$expiring_certs certificate(s) expiring within 30 days" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
else
    echo "No certificates configured or failed to query certificates."
fi

# Check environment workload profiles (if using workload profiles)
workload_profiles=$(echo "$env_data" | jq '.properties.workloadProfiles // []')
workload_profile_count=$(echo "$workload_profiles" | jq 'length')

echo "Workload Profiles: $workload_profile_count"

if [[ $workload_profile_count -gt 0 ]]; then
    echo "Analyzing workload profiles..."
    
    while IFS= read -r profile; do
        profile_name=$(echo "$profile" | jq -r '.name')
        profile_type=$(echo "$profile" | jq -r '.workloadProfileType')
        min_nodes=$(echo "$profile" | jq -r '.minimumCount // 0')
        max_nodes=$(echo "$profile" | jq -r '.maximumCount // 0')
        
        echo "  Profile: $profile_name ($profile_type)"
        echo "    Min nodes: $min_nodes, Max nodes: $max_nodes"
        
        # Check if profile has no capacity
        if [[ $min_nodes -eq 0 && $max_nodes -eq 0 ]]; then
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Workload Profile With No Capacity" \
                --arg nextStep "Configure capacity for workload profile $profile_name in environment $CONTAINER_APP_ENV_NAME." \
                --arg severity "3" \
                --arg details "Workload profile $profile_name has no minimum or maximum capacity configured" \
                '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
            )
        fi
    done < <(echo "$workload_profiles" | jq -c '.[]')
fi

# Generate environment health summary
summary_file="container_app_env_summary.txt"
echo "Environment Health Summary: $CONTAINER_APP_ENV_NAME" > "$summary_file"
echo "=============================================" >> "$summary_file"
echo "Provisioning State: $provisioning_state" >> "$summary_file"
echo "Environment Type: $env_type" >> "$summary_file"
echo "Location: $location" >> "$summary_file"
echo "Zone Redundant: $zone_redundant" >> "$summary_file"
echo "" >> "$summary_file"
echo "Network Configuration:" >> "$summary_file"
echo "  Internal VNET: $vnet_internal" >> "$summary_file"
echo "  Infrastructure Subnet: $infrastructure_subnet_id" >> "$summary_file"
echo "" >> "$summary_file"
echo "Logging Configuration:" >> "$summary_file"
echo "  Destination: $log_destination" >> "$summary_file"
echo "  Workspace ID: $workspace_id" >> "$summary_file"
echo "" >> "$summary_file"
echo "Container Apps:" >> "$summary_file"
echo "  Total Apps: ${app_count:-0}" >> "$summary_file"
echo "  Unhealthy Apps: ${unhealthy_apps:-0}" >> "$summary_file"
echo "" >> "$summary_file"
echo "Certificates: ${cert_count:-0}" >> "$summary_file"
echo "Expiring Certificates: ${expiring_certs:-0}" >> "$summary_file"
echo "" >> "$summary_file"
echo "Workload Profiles: $workload_profile_count" >> "$summary_file"

# Add issues to the summary
issue_count=$(echo "$issues_json" | jq '.issues | length')
echo "" >> "$summary_file"
echo "Issues Detected: $issue_count" >> "$summary_file"
echo "=============================================" >> "$summary_file"
echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"

# Save JSON outputs
issues_file="container_app_env_issues.json"
env_file="container_app_env_data.json"

echo "$issues_json" > "$issues_file"
echo "$env_data" > "$env_file"

# Final output
echo "Summary generated at: $summary_file"
echo "Environment data saved at: $env_file"
echo "Issues JSON saved at: $issues_file" 