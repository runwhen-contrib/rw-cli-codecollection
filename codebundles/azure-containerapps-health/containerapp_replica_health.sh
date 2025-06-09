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

# Get the Container App details
echo "Checking Container App: $CONTAINER_APP_NAME in Resource Group: $AZ_RESOURCE_GROUP"
container_app_data=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json)

if [[ -z "$container_app_data" ]]; then
    echo "Error: Container App $CONTAINER_APP_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

# Check the provisioning state of the Container App
provisioning_state=$(echo "$container_app_data" | jq -r '.properties.provisioningState')
echo "Container App provisioning state: $provisioning_state"

# Get replica information
echo "Fetching replica information for Container App: $CONTAINER_APP_NAME"
replicas_data=$(az containerapp replica list --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json 2>/dev/null)

issues_json='{"issues": []}'

# Check if provisioning state is healthy
if [[ "$provisioning_state" != "Succeeded" ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Container App Provisioning Issue" \
        --arg nextStep "Check Container App deployment status and resolve provisioning issues for $CONTAINER_APP_NAME in $AZ_RESOURCE_GROUP." \
        --arg severity "2" \
        --arg details "Container App provisioning state: $provisioning_state" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Analyze replica data
if [[ -z "$replicas_data" || "$replicas_data" == "null" || $(echo "$replicas_data" | jq '. | length') -eq 0 ]]; then
    echo "No replica information available."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Replica Information Available" \
        --arg nextStep "Investigate why replica information is not available for $CONTAINER_APP_NAME in $AZ_RESOURCE_GROUP." \
        --arg severity "3" \
        --arg details "No replica data returned from Azure CLI." \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
else
    # Count total replicas and analyze their status
    total_replicas=$(echo "$replicas_data" | jq '. | length')
    running_replicas=0
    failed_replicas=0
    
    echo "Analyzing $total_replicas replicas..."
    
    # Count replicas by status
    while IFS= read -r replica; do
        replica_name=$(echo "$replica" | jq -r '.name')
        running_state=$(echo "$replica" | jq -r '.properties.runningState // "Unknown"')
        
        case "$running_state" in
            "Running")
                running_replicas=$((running_replicas + 1))
                ;;
            "Failed"|"Terminated"|"Unknown")
                failed_replicas=$((failed_replicas + 1))
                echo "Found failed replica: $replica_name with state: $running_state"
                ;;
        esac
    done < <(echo "$replicas_data" | jq -c '.[]')
    
    # Check if we have minimum required replicas
    if [[ $total_replicas -lt $REPLICA_COUNT_MIN ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Insufficient Replica Count" \
            --arg nextStep "Scale up Container App $CONTAINER_APP_NAME to meet minimum replica requirements." \
            --arg severity "2" \
            --arg details "Current replicas: $total_replicas, Required minimum: $REPLICA_COUNT_MIN" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    # Check for failed replicas
    if [[ $failed_replicas -gt 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Failed Replicas Detected" \
            --arg nextStep "Investigate failed replicas for Container App $CONTAINER_APP_NAME. Check logs and resource constraints." \
            --arg severity "3" \
            --arg details "Failed replicas: $failed_replicas out of $total_replicas total replicas" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    # Check if no replicas are running
    if [[ $running_replicas -eq 0 ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "No Running Replicas" \
            --arg nextStep "Immediately investigate Container App $CONTAINER_APP_NAME. No replicas are running." \
            --arg severity "1" \
            --arg details "No running replicas out of $total_replicas total replicas" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
fi

# Get Container App scaling configuration
echo "Checking scaling configuration..."
scaling_config=$(echo "$container_app_data" | jq '.properties.template.scale // {}')
min_replicas=$(echo "$scaling_config" | jq -r '.minReplicas // 0')
max_replicas=$(echo "$scaling_config" | jq -r '.maxReplicas // 10')

# Generate the replica health summary
summary_file="container_app_replica_summary.txt"
echo "Replica Health Summary for Container App: $CONTAINER_APP_NAME" > "$summary_file"
echo "=======================================================" >> "$summary_file"
echo "Provisioning State: $provisioning_state" >> "$summary_file"
echo "Total Replicas: ${total_replicas:-0}" >> "$summary_file"
echo "Running Replicas: ${running_replicas:-0}" >> "$summary_file"
echo "Failed Replicas: ${failed_replicas:-0}" >> "$summary_file"
echo "Scaling Configuration:" >> "$summary_file"
echo "  Min Replicas: $min_replicas" >> "$summary_file"
echo "  Max Replicas: $max_replicas" >> "$summary_file"

if [[ $failed_replicas -gt 0 ]]; then
    echo "Some replicas are failing. Investigate application issues and resource constraints." >> "$summary_file"
elif [[ $total_replicas -lt $REPLICA_COUNT_MIN ]]; then
    echo "Replica count is below minimum threshold. Consider scaling up." >> "$summary_file"
elif [[ $running_replicas -eq 0 ]]; then
    echo "CRITICAL: No replicas are running. Immediate attention required." >> "$summary_file"
else
    echo "All replicas are healthy." >> "$summary_file"
fi

# Add issues to the summary
issue_count=$(echo "$issues_json" | jq '.issues | length')
echo "" >> "$summary_file"
echo "Issues Detected: $issue_count" >> "$summary_file"
echo "=======================================================" >> "$summary_file"
echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"

# Save JSON outputs
issues_file="container_app_replica_issues.json"
replicas_file="container_app_replicas_data.json"

echo "$issues_json" > "$issues_file"
echo "$replicas_data" > "$replicas_file"

# Final output
echo "Summary generated at: $summary_file"
echo "Replicas data saved at: $replicas_file"
echo "Issues JSON saved at: $issues_file" 