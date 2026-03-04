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
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-$azure_devops_pat}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="service_connections_issues.json"
issues_json='[]'

echo "Analyzing Azure DevOps Service Connections..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Project:      $AZURE_DEVOPS_PROJECT"

az devops configure --defaults project="$AZURE_DEVOPS_PROJECT" --output none
setup_azure_auth

# Get list of service connections
echo "Retrieving service connections in project..."
if ! az_with_retry az devops service-endpoint list --output json; then
    echo "ERROR: Could not list service connections."
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Failed to List Service Connections" \
        --arg details "Azure DevOps API was unreachable or returned an error after $AZ_RETRY_COUNT retry attempts." \
        --arg severity "3" \
        --arg nextStep "Check if you have sufficient permissions to view service connections. Verify Azure DevOps API availability." \
        '. += [{
           "title": $title,
           "details": $details,
           "next_steps": $nextStep,
           "severity": ($severity | tonumber)
        }]')
    echo "$issues_json" > "$OUTPUT_FILE"
    exit 1
fi
connections="$AZ_RESULT"

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
            --arg title "Service Connection \`$conn_name\` is Not Ready in Project \`$AZURE_DEVOPS_PROJECT\`" \
            --arg details "Service connection \`$conn_name\` (Type: $conn_type) is not in a ready state. Target URL: $conn_url. Created by: $created_by. This may block pipelines that depend on this connection for deployments or external service access." \
            --arg severity "3" \
            --arg nextStep "Verify the credentials for service connection \`$conn_name\` ($conn_type) are still valid. Check if the target service at $conn_url is accessible. Try to refresh or recreate the connection in project settings." \
            '. += [{
               "title": $title,
               "details": $details,
               "next_steps": $nextStep,
               "severity": ($severity | tonumber)
             }]')
    fi
done

# Clean up temporary files
rm -f connections.json

# Write final JSON
echo "$issues_json" > "$OUTPUT_FILE"
echo "Azure DevOps service connections analysis completed. Saved results to $OUTPUT_FILE"
