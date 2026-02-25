#!/usr/bin/env bash
set -euo pipefail
# set -x

# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG - Azure DevOps organization name
#   AUTH_TYPE (optional, default: service_principal)
#   AZURE_DEVOPS_PAT (required if AUTH_TYPE=pat)
#
# This script:
#   1) Discovers all projects in the specified Azure DevOps organization
#   2) Outputs results in JSON format for the runbook to consume
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AUTH_TYPE:=service_principal}"

OUTPUT_FILE="discovered_projects.json"
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"

echo "Discovering Azure DevOps Projects..."
echo "Organization: $AZURE_DEVOPS_ORG"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="$ORG_URL" --output none

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
    echo "$AZURE_DEVOPS_PAT" | az devops login --organization "$ORG_URL"
else
    echo "ERROR: Invalid AUTH_TYPE. Must be 'service_principal' or 'pat'"
    exit 1
fi

# Get list of projects
echo "Retrieving all projects in organization..."
if ! projects_json=$(az devops project list --org "$ORG_URL" --output json 2>projects_err.log); then
    err_msg=$(cat projects_err.log)
    rm -f projects_err.log
    
    echo "ERROR: Could not list projects."
    echo "Error details: $err_msg"
    
    # Create empty JSON array as fallback
    echo '[]' > "$OUTPUT_FILE"
    exit 1
fi
rm -f projects_err.log

# Extract the project data (Azure CLI returns {value: [projects]})
projects_array=$(echo "$projects_json" | jq '.value // .')

# Write the projects array to output file
echo "$projects_array" > "$OUTPUT_FILE"

# Count projects for logging
project_count=$(echo "$projects_array" | jq '. | length')
echo "Discovered $project_count projects"

# Output project names to stdout for debugging
echo "Projects found:"
echo "$projects_array" | jq -r '.[].name' | while read -r project_name; do
    echo "  - $project_name"
done

echo "Project discovery completed. Results saved to $OUTPUT_FILE" 