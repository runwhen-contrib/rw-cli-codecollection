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

echo "Checking configuration health for Container App: $CONTAINER_APP_NAME"

# Get the Container App configuration
container_app_config=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json)

if [[ -z "$container_app_config" ]]; then
    echo "Error: Container App $CONTAINER_APP_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

issues_json='{"issues": []}'

# Check provisioning state
provisioning_state=$(echo "$container_app_config" | jq -r '.properties.provisioningState')
echo "Provisioning State: $provisioning_state"

if [[ "$provisioning_state" != "Succeeded" ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Container App Provisioning Failed" \
        --arg nextStep "Check deployment logs and resolve provisioning issues for $CONTAINER_APP_NAME." \
        --arg severity "1" \
        --arg details "Provisioning state: $provisioning_state" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check scaling configuration
echo "Analyzing scaling configuration..."
scale_config=$(echo "$container_app_config" | jq '.properties.template.scale // {}')
min_replicas=$(echo "$scale_config" | jq -r '.minReplicas // 0')
max_replicas=$(echo "$scale_config" | jq -r '.maxReplicas // 10')

echo "Scale Configuration - Min: $min_replicas, Max: $max_replicas"

# Check if scaling rules are configured
scale_rules=$(echo "$scale_config" | jq '.rules // []')
scale_rules_count=$(echo "$scale_rules" | jq 'length')

if [[ $scale_rules_count -eq 0 && $max_replicas -gt $min_replicas ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Auto-scaling Rules Configured" \
        --arg nextStep "Configure auto-scaling rules for Container App $CONTAINER_APP_NAME to enable automatic scaling." \
        --arg severity "4" \
        --arg details "Max replicas ($max_replicas) > Min replicas ($min_replicas) but no scaling rules are configured" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

if [[ $min_replicas -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Zero Minimum Replicas Configuration" \
        --arg nextStep "Consider setting minimum replicas > 0 for Container App $CONTAINER_APP_NAME to avoid cold start delays." \
        --arg severity "4" \
        --arg details "Minimum replicas set to 0 may cause cold start issues" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check container configuration
echo "Analyzing container configuration..."
containers=$(echo "$container_app_config" | jq '.properties.template.containers // []')
container_count=$(echo "$containers" | jq 'length')

echo "Number of containers: $container_count"

# Analyze each container
for i in $(seq 0 $((container_count - 1))); do
    container=$(echo "$containers" | jq ".[$i]")
    container_name=$(echo "$container" | jq -r '.name')
    
    echo "Analyzing container: $container_name"
    
    # Check resource limits
    resources=$(echo "$container" | jq '.resources // {}')
    cpu_limit=$(echo "$resources" | jq -r '.cpu // "not set"')
    memory_limit=$(echo "$resources" | jq -r '.memory // "not set"')
    
    echo "  CPU limit: $cpu_limit"
    echo "  Memory limit: $memory_limit"
    
    if [[ "$cpu_limit" == "not set" || "$cpu_limit" == "null" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No CPU Limit Set" \
            --arg nextStep "Set CPU limits for container $container_name in Container App $CONTAINER_APP_NAME to prevent resource contention." \
            --arg severity "3" \
            --arg details "Container $container_name has no CPU limit configured" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    if [[ "$memory_limit" == "not set" || "$memory_limit" == "null" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Memory Limit Set" \
            --arg nextStep "Set memory limits for container $container_name in Container App $CONTAINER_APP_NAME to prevent out-of-memory issues." \
            --arg severity "3" \
            --arg details "Container $container_name has no memory limit configured" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    # Check health probes
    probes=$(echo "$container" | jq '.probes // []')
    liveness_probe=$(echo "$probes" | jq '.[] | select(.type == "Liveness")')
    readiness_probe=$(echo "$probes" | jq '.[] | select(.type == "Readiness")')
    startup_probe=$(echo "$probes" | jq '.[] | select(.type == "Startup")')
    
    if [[ -z "$liveness_probe" || "$liveness_probe" == "null" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Liveness Probe Configured" \
            --arg nextStep "Configure liveness probe for container $container_name to enable automatic restart of unhealthy containers." \
            --arg severity "3" \
            --arg details "Container $container_name has no liveness probe configured" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    if [[ -z "$readiness_probe" || "$readiness_probe" == "null" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Readiness Probe Configured" \
            --arg nextStep "Configure readiness probe for container $container_name to ensure traffic is only sent to ready containers." \
            --arg severity "4" \
            --arg details "Container $container_name has no readiness probe configured" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
done

# Check ingress configuration
echo "Analyzing ingress configuration..."
ingress=$(echo "$container_app_config" | jq '.properties.configuration.ingress // {}')
ingress_enabled=$(echo "$ingress" | jq -r '.external // false')
target_port=$(echo "$ingress" | jq -r '.targetPort // "not set"')

echo "Ingress enabled: $ingress_enabled"
echo "Target port: $target_port"

if [[ "$ingress_enabled" == "true" && ("$target_port" == "not set" || "$target_port" == "null") ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Ingress Enabled Without Target Port" \
        --arg nextStep "Configure target port for ingress in Container App $CONTAINER_APP_NAME." \
        --arg severity "2" \
        --arg details "Ingress is enabled but no target port is configured" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check secrets configuration
echo "Analyzing secrets configuration..."
secrets=$(echo "$container_app_config" | jq '.properties.configuration.secrets // []')
secrets_count=$(echo "$secrets" | jq 'length')

echo "Number of secrets configured: $secrets_count"

# Check if containers reference environment variables that might need secrets
env_vars_with_secrets=0
for i in $(seq 0 $((container_count - 1))); do
    container=$(echo "$containers" | jq ".[$i]")
    env_vars=$(echo "$container" | jq '.env // []')
    
    secret_refs=$(echo "$env_vars" | jq '.[] | select(.secretRef != null)')
    if [[ -n "$secret_refs" && "$secret_refs" != "null" ]]; then
        env_vars_with_secrets=$((env_vars_with_secrets + 1))
    fi
done

# Check volume mounts
echo "Analyzing volume mounts..."
volume_mounts=$(echo "$container_app_config" | jq '.properties.template.volumes // []')
volume_count=$(echo "$volume_mounts" | jq 'length')

echo "Number of volumes: $volume_count"

# Check dapr configuration if enabled
dapr_config=$(echo "$container_app_config" | jq '.properties.configuration.dapr // {}')
dapr_enabled=$(echo "$dapr_config" | jq -r '.enabled // false')

echo "Dapr enabled: $dapr_enabled"

if [[ "$dapr_enabled" == "true" ]]; then
    dapr_app_id=$(echo "$dapr_config" | jq -r '.appId // "not set"')
    if [[ "$dapr_app_id" == "not set" || "$dapr_app_id" == "null" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Dapr Enabled Without App ID" \
            --arg nextStep "Configure Dapr app ID for Container App $CONTAINER_APP_NAME when Dapr is enabled." \
            --arg severity "3" \
            --arg details "Dapr is enabled but no app ID is configured" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
fi

# Generate configuration summary
summary_file="container_app_config_summary.txt"
echo "Configuration Health Summary for Container App: $CONTAINER_APP_NAME" > "$summary_file"
echo "============================================================" >> "$summary_file"
echo "Provisioning State: $provisioning_state" >> "$summary_file"
echo "Scaling Configuration:" >> "$summary_file"
echo "  Min Replicas: $min_replicas" >> "$summary_file"
echo "  Max Replicas: $max_replicas" >> "$summary_file"
echo "  Scaling Rules: $scale_rules_count" >> "$summary_file"
echo "Container Configuration:" >> "$summary_file"
echo "  Number of Containers: $container_count" >> "$summary_file"
echo "Ingress Configuration:" >> "$summary_file"
echo "  External Ingress: $ingress_enabled" >> "$summary_file"
echo "  Target Port: $target_port" >> "$summary_file"
echo "Security Configuration:" >> "$summary_file"
echo "  Secrets Count: $secrets_count" >> "$summary_file"
echo "  Containers with Secret References: $env_vars_with_secrets" >> "$summary_file"
echo "Dapr Configuration:" >> "$summary_file"
echo "  Dapr Enabled: $dapr_enabled" >> "$summary_file"
echo "Volume Configuration:" >> "$summary_file"
echo "  Volume Mounts: $volume_count" >> "$summary_file"

# Add issues to the summary
issue_count=$(echo "$issues_json" | jq '.issues | length')
echo "" >> "$summary_file"
echo "Issues Detected: $issue_count" >> "$summary_file"
echo "============================================================" >> "$summary_file"
echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"

# Save JSON outputs
issues_file="container_app_config_issues.json"
config_file="container_app_config_data.json"

echo "$issues_json" > "$issues_file"
echo "$container_app_config" > "$config_file"

# Final output
echo "Summary generated at: $summary_file"
echo "Configuration data saved at: $config_file"
echo "Issues JSON saved at: $issues_file" 