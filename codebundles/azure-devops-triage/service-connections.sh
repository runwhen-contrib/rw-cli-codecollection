#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# This script:
#   1) Lists all service connections in the specified Azure DevOps project
#   2) Checks the status of each service connection
#   3) Validates connectivity to external services
#   4) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"

OUTPUT_FILE="service_connections_issues.json"
issues_json='[]'

echo "Analyzing Azure DevOps Service Connections..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" project="$AZURE_DEVOPS_PROJECT" --output none

# Get list of service connections
echo "Retrieving service connections in project..."
if ! connections=$(az devops service-endpoint list --output json 2>connections_err.log); then
    err_msg=$(cat connections_err.log)
    rm -f connections_err.log
    
    echo "ERROR: Could not list service connections."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Service Connections" \
        --arg details "$err_msg" \
        --arg severity "4" \
        --arg nextStep "Check if you have sufficient permissions to view service connections." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_step": $nextStep,
           "severity": ($severity | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f connections_err.log

# Process each service connection
for connection in $(echo "${connections}" | jq -c '.[]'); do
    conn_id=$(echo $connection | jq -r '.id')
    conn_name=$(echo $connection | jq -r '.name')
    conn_type=$(echo $connection | jq -r '.type')
    conn_url=$(echo $connection | jq -r '.url // "N/A"')
    is_ready=$(echo $connection | jq -r '.isReady // false')
    created_by=$(echo $connection | jq -r '.createdBy.displayName // "Unknown"')
    
    echo "Processing Service Connection: $conn_name (ID: $conn_id, Type: $conn_type)"
    
    # Check if connection is not ready
    if [[ "$is_ready" != "true" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Service Connection \`$conn_name\` is Not Ready" \
            --arg details "Connection type: $conn_type, URL: $conn_url, Created by: $created_by" \
            --arg severity "3" \
            --arg nextStep "Verify the service connection configuration and credentials. Try to refresh or recreate the connection." \
            '. += [{
               "title": $title,
               "details": $details,
               "next_step": $nextStep,
               "severity": ($severity | tonumber)
             }]')
        continue
    fi
    
    # Check connection health by type
    if [[ "$conn_type" == "azurerm" || "$conn_type" == "azure" ]]; then
        # For Azure connections, try to validate
        if ! validation=$(az devops service-endpoint test --id "$conn_id" --output json 2>validation_err.log); then
            err_msg=$(cat validation_err.log)
            rm -f validation_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed to Validate Azure Service Connection \`$conn_name\`" \
                --arg details "Connection type: $conn_type, Error: $err_msg" \
                --arg severity "3" \
                --arg nextStep "Check if the service principal credentials are valid and not expired. Verify the Azure subscription is active." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
        else
            # Check validation result
            is_valid=$(echo "$validation" | jq -r '.isValid // false')
            if [[ "$is_valid" != "true" ]]; then
                error_message=$(echo "$validation" | jq -r '.errorMessage // "Unknown error"')
                
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Invalid Azure Service Connection \`$conn_name\`" \
                    --arg details "Connection type: $conn_type, Error: $error_message" \
                    --arg severity "3" \
                    --arg nextStep "Update the service connection with valid credentials. Check if the service principal has the required permissions." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber)
                     }]')
            fi
        fi
    elif [[ "$conn_type" == "github" || "$conn_type" == "githubenterprise" ]]; then
        # For GitHub connections, we can't directly test but can check usage
        if ! usage=$(az devops service-endpoint get --id "$conn_id" --output json 2>usage_err.log); then
            err_msg=$(cat usage_err.log)
            rm -f usage_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed to Get Details for GitHub Connection \`$conn_name\`" \
                --arg details "Connection type: $conn_type, Error: $err_msg" \
                --arg severity "3" \
                --arg nextStep "Check if the connection still exists and you have permissions to view it." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
        else
            # Check if authorization is using a personal access token that might expire
            auth_scheme=$(echo "$usage" | jq -r '.authorization.scheme // "Unknown"')
            if [[ "$auth_scheme" == "PersonalAccessToken" ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "GitHub Connection \`$conn_name\` Uses Personal Access Token" \
                    --arg details "Connection type: $conn_type, Authorization scheme: $auth_scheme" \
                    --arg severity "2" \
                    --arg nextStep "Consider using GitHub Apps or OAuth instead of PAT for better security and to avoid token expiration issues." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber)
                     }]')
            fi
        fi
    elif [[ "$conn_type" == "dockerregistry" ]]; then
        # For Docker registry connections, check if it's using a username/password that might expire
        if ! registry_details=$(az devops service-endpoint get --id "$conn_id" --output json 2>registry_err.log); then
            err_msg=$(cat registry_err.log)
            rm -f registry_err.log
            
            issues_json=$(echo "$issues_json" | jq \
                --arg title "Failed to Get Details for Docker Registry Connection \`$conn_name\`" \
                --arg details "Connection type: $conn_type, Error: $err_msg" \
                --arg severity "3" \
                --arg nextStep "Check if the connection still exists and you have permissions to view it." \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "next_step": $nextStep,
                   "severity": ($severity | tonumber)
                 }]')
        else
            # Check if it's using basic authentication
            auth_scheme=$(echo "$registry_details" | jq -r '.authorization.scheme // "Unknown"')
            if [[ "$auth_scheme" == "UsernamePassword" ]]; then
                issues_json=$(echo "$issues_json" | jq \
                    --arg title "Docker Registry Connection \`$conn_name\` Uses Username/Password Authentication" \
                    --arg details "Connection type: $conn_type, Authorization scheme: $auth_scheme" \
                    --arg severity "2" \
                    --arg nextStep "Consider using service principals or managed identities for Azure Container Registry, or access tokens with limited scope for other registries." \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "next_step": $nextStep,
                       "severity": ($severity | tonumber)
                     }]')
            fi
        fi
    fi
    
    # Check for unused service connections (no recent usage)
    # Note: This would require additional API calls to check usage history, which is not directly available via az CLI
    # This is a placeholder for that functionality
done

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps service