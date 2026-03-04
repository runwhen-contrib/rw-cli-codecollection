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
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-$azure_devops_pat}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="discovered_projects.json"
ORG_URL="https://dev.azure.com/$AZURE_DEVOPS_ORG"

echo "Discovering Azure DevOps Projects..."
echo "Organization: $AZURE_DEVOPS_ORG"

setup_azure_auth

# Get list of projects
echo "Retrieving all projects in organization..."
if ! az_with_retry az devops project list --org "$ORG_URL" --output json; then
    echo "ERROR: Could not list projects after $AZ_RETRY_COUNT retry attempts."
    echo '[]' > "$OUTPUT_FILE"
    exit 1
fi
projects_json="$AZ_RESULT"

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