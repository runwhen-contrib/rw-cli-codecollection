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

echo "Fetching logs for Container App: $CONTAINER_APP_NAME in Resource Group: $AZ_RESOURCE_GROUP"

# Check if the Container App exists
container_app_exists=$(az containerapp show --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json 2>/dev/null)
if [[ -z "$container_app_exists" ]]; then
    echo "Error: Container App $CONTAINER_APP_NAME not found in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

# Get recent logs from the Container App
echo "Retrieving recent logs (last ${TIME_PERIOD_MINUTES} minutes)..."

# Try to get logs using az containerapp logs
logs_output=$(az containerapp logs show \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --follow false \
    --tail 100 \
    --output table 2>/dev/null)

if [[ $? -eq 0 && -n "$logs_output" ]]; then
    echo "=== Container App Logs (Last 100 lines) ==="
    echo "$logs_output"
else
    echo "No logs available or logs command failed. Trying alternative method..."
    
    # Alternative: Get logs using Log Analytics if available
    echo "Attempting to retrieve logs using Log Analytics..."
    
    # Get the Container Apps Environment
    env_name=$(echo "$container_app_exists" | jq -r '.properties.environmentId' | sed 's|.*/||')
    
    if [[ -n "$env_name" && "$env_name" != "null" ]]; then
        echo "Container Apps Environment: $env_name"
        
        # Try to get workspace info for the environment
        workspace_info=$(az containerapp env show \
            --name "$env_name" \
            --resource-group "$AZ_RESOURCE_GROUP" \
            --query "properties.appLogsConfiguration.logAnalyticsConfiguration.customerId" \
            --output tsv 2>/dev/null)
        
        if [[ -n "$workspace_info" && "$workspace_info" != "null" ]]; then
            echo "Log Analytics Workspace ID: $workspace_info"
            
            # Try to query logs using az monitor log-analytics
            kql_query="ContainerAppConsoleLogs_CL | where ContainerAppName_s == '$CONTAINER_APP_NAME' | where TimeGenerated > ago(${TIME_PERIOD_MINUTES}m) | order by TimeGenerated desc | take 50"
            
            log_query_result=$(az monitor log-analytics query \
                --workspace "$workspace_info" \
                --analytics-query "$kql_query" \
                --output table 2>/dev/null)
            
            if [[ $? -eq 0 && -n "$log_query_result" ]]; then
                echo "=== Container App Logs from Log Analytics ==="
                echo "$log_query_result"
            else
                echo "Log Analytics query failed or returned no results."
            fi
        else
            echo "No Log Analytics workspace found for the Container Apps Environment."
        fi
    else
        echo "Could not determine Container Apps Environment."
    fi
fi

# Get revision information and their logs
echo ""
echo "=== Revision Information ==="
revisions=$(az containerapp revision list \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --output json 2>/dev/null)

if [[ -n "$revisions" && "$revisions" != "null" ]]; then
    echo "Available revisions:"
    echo "$revisions" | jq -r '.[] | "- \(.name) (Traffic: \(.properties.trafficWeight // 0)%, Active: \(.properties.active))"'
    
    # Get logs for active revisions
    active_revisions=$(echo "$revisions" | jq -r '.[] | select(.properties.active == true) | .name')
    
    if [[ -n "$active_revisions" ]]; then
        echo ""
        echo "=== Logs from Active Revisions ==="
        while IFS= read -r revision_name; do
            echo "--- Logs for revision: $revision_name ---"
            revision_logs=$(az containerapp logs show \
                --name "$CONTAINER_APP_NAME" \
                --resource-group "$AZ_RESOURCE_GROUP" \
                --revision "$revision_name" \
                --follow false \
                --tail 20 \
                --output table 2>/dev/null)
            
            if [[ $? -eq 0 && -n "$revision_logs" ]]; then
                echo "$revision_logs"
            else
                echo "No logs available for revision $revision_name"
            fi
            echo ""
        done <<< "$active_revisions"
    fi
else
    echo "No revision information available."
fi

# Get replica logs if available
echo "=== Replica Logs ==="
replicas=$(az containerapp replica list \
    --name "$CONTAINER_APP_NAME" \
    --resource-group "$AZ_RESOURCE_GROUP" \
    --output json 2>/dev/null)

if [[ -n "$replicas" && "$replicas" != "null" && $(echo "$replicas" | jq '. | length') -gt 0 ]]; then
    echo "Getting logs from individual replicas:"
    
    echo "$replicas" | jq -r '.[] | select(.properties.runningState == "Running") | .name' | head -3 | while IFS= read -r replica_name; do
        echo "--- Logs for replica: $replica_name ---"
        replica_logs=$(az containerapp logs show \
            --name "$CONTAINER_APP_NAME" \
            --resource-group "$AZ_RESOURCE_GROUP" \
            --replica "$replica_name" \
            --follow false \
            --tail 10 \
            --output table 2>/dev/null)
        
        if [[ $? -eq 0 && -n "$replica_logs" ]]; then
            echo "$replica_logs"
        else
            echo "No logs available for replica $replica_name"
        fi
        echo ""
    done
else
    echo "No replica information available."
fi

echo ""
echo "=== Log Collection Summary ==="
echo "Container App: $CONTAINER_APP_NAME"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Time Period: Last ${TIME_PERIOD_MINUTES} minutes"
echo "Log collection completed." 