#!/bin/bash

# Discover all repositories in an Azure DevOps project
# Outputs JSON format with repository information

set -euo pipefail

# Initialize variables
AZURE_DEVOPS_ORG="${AZURE_DEVOPS_ORG:-}"
AZURE_DEVOPS_PROJECT="${AZURE_DEVOPS_PROJECT:-}"
AUTH_TYPE="${AUTH_TYPE:-service_principal}"

# Validate required variables
if [[ -z "$AZURE_DEVOPS_ORG" ]]; then
    echo "Error: AZURE_DEVOPS_ORG environment variable is required"
    exit 1
fi

if [[ -z "$AZURE_DEVOPS_PROJECT" ]]; then
    echo "Error: AZURE_DEVOPS_PROJECT environment variable is required"
    exit 1
fi

echo "Discovering repositories in project: $AZURE_DEVOPS_PROJECT"
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Authentication type: $AUTH_TYPE"

# Set up authentication
if [[ "$AUTH_TYPE" == "service_principal" ]]; then
    echo "Authenticating with service principal..."
    if ! az login --service-principal -u "$AZURE_CLIENT_ID" -p "$AZURE_CLIENT_SECRET" --tenant "$AZURE_TENANT_ID" >/dev/null 2>&1; then
        echo "Error: Failed to authenticate with service principal"
        exit 1
    fi
elif [[ "$AUTH_TYPE" == "pat" ]]; then
    echo "Using PAT authentication..."
    if [[ -z "${AZURE_DEVOPS_EXT_PAT:-}" ]]; then
        echo "Error: AZURE_DEVOPS_EXT_PAT environment variable is required for PAT authentication"
        exit 1
    fi
else
    echo "Warning: Unknown authentication type '$AUTH_TYPE', attempting service principal..."
fi

# Install Azure DevOps extension if not already installed
if ! az extension show --name azure-devops >/dev/null 2>&1; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --yes
fi

# Set default organization
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG"

echo "Fetching repositories from project '$AZURE_DEVOPS_PROJECT'..."

# Get all repositories in the project
if ! REPOS_JSON=$(az repos list --project "$AZURE_DEVOPS_PROJECT" --output json 2>/dev/null); then
    echo "Error: Failed to fetch repositories. Check project name and permissions."
    echo "[]" > discovered_repositories.json
    exit 1
fi

# Extract repository information
REPO_COUNT=$(echo "$REPOS_JSON" | jq length)
echo "Found $REPO_COUNT repositories"

# Create simplified repository list
SIMPLIFIED_REPOS=$(echo "$REPOS_JSON" | jq '[.[] | {
    name: .name,
    id: .id,
    url: .webUrl,
    defaultBranch: .defaultBranch,
    size: .size
}]')

# Save to file
echo "$SIMPLIFIED_REPOS" > discovered_repositories.json

echo "Repository discovery completed successfully"
echo "Results saved to discovered_repositories.json"

# Also output repository names for logging
echo "Repository names:"
echo "$SIMPLIFIED_REPOS" | jq -r '.[].name' 