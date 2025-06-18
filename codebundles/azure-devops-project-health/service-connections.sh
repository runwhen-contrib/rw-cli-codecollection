#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AZURE_DEVOPS_PROJECT
#
# This script:
#   1) Lists all service connections in the specified Azure DevOps project
#   2) Checks if each service connection is ready
#   3) Outputs results in JSON format
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AZURE_DEVOPS_PROJECT:?Must set AZURE_DEVOPS_PROJECT}"
: "${AUTH_TYPE:=service_principal}"

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

# Setup authentication
if [ "$AUTH_TYPE" = "service_principal" ]; then
    echo "Using service principal authentication..."
    # Service principal authentication is handled by Azure CLI login
elif [ "$AUTH_TYPE" = "pat" ]; then
    if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
        echo "ERROR: AZURE_DEVOPS_PAT must be set when AUTH_TYPE=pat"
        exit 1
    fi
    echo "Using PAT authentication..."
    echo "$AZURE_DEVOPS_PAT" | az devops login --organization "https://dev.azure.com/$AZURE_DEVOPS_ORG"
else
    echo "ERROR: Invalid AUTH_TYPE. Must be 'service_principal' or 'pat'"
    exit 1
fi

# Get list of service connections
echo "Retrieving service connections in project..."
if ! connections=$(az devops service-endpoint list --output json 2>connections_err.log); then
    err_msg=$(cat connections_err.log)
    rm -f connections_err.log
    
    echo "ERROR: Could not list service connections."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Service Connections" \
        --arg details "$err_msg" \
        --arg severity "3" \
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

# Save connections to a file to avoid subshell issues
echo "$connections" > connections.json

# Get the number of connections
connection_count=$(jq '. | length' connections.json)

# Process each service connection using a for loop instead of pipe to while
for ((i=0; i<connection_count; i++)); do
    connection_json=$(jq -c ".[${i}]" connections.json)
    
    # Extract values from JSON using jq
    conn_id=$(echo "$connection_json" | jq -r '.id')
    conn_name=$(echo "$connection_json" | jq -r '.name')
    conn_type=$(echo "$connection_json" | jq -r '.type')
    conn_url=$(echo "$connection_json" | jq -r '.url // "N/A"')
    is_ready=$(echo "$connection_json" | jq -r '.isReady // false')
    created_by=$(echo "$connection_json" | jq -r '.createdBy.displayName // "Unknown"')
    
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
    fi
done

# Clean up temporary files
rm -f connections.json

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps service connections analysis completed. Saved results to $OUTPUT_FILE"
