#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#
# This script:
#   1) Checks Azure DevOps service health status
#   2) Verifies organization accessibility
#   3) Tests basic API connectivity
#   4) Reports any service-level issues
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"

OUTPUT_FILE="organization_service_health.json"
health_json='[]'

echo "Checking Azure DevOps Organization Service Health..."
echo "Organization: $AZURE_DEVOPS_ORG"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" --output none

# Test basic organization connectivity
echo "Testing organization connectivity..."
if ! org_info=$(az devops project list --output json 2>org_err.log); then
    err_msg=$(cat org_err.log)
    rm -f org_err.log
    
    health_json=$(echo "$health_json" | jq \
        --arg title "Organization Connectivity Issue" \
        --arg details "Cannot connect to organization $AZURE_DEVOPS_ORG: $err_msg" \
        --arg severity "4" \
        --arg next_steps "Check if organization exists, verify permissions, and ensure network connectivity to Azure DevOps" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$health_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f org_err.log

echo "Organization connectivity: OK"

# Check if we can list projects (basic functionality test)
project_count=$(echo "$org_info" | jq '. | length')
echo "Found $project_count projects in organization"

if [ "$project_count" -eq 0 ]; then
    health_json=$(echo "$health_json" | jq \
        --arg title "No Projects Found" \
        --arg details "Organization $AZURE_DEVOPS_ORG has no projects or insufficient permissions to view projects" \
        --arg severity "3" \
        --arg next_steps "Verify that projects exist in the organization and that the service principal has appropriate permissions" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Test agent pools API (organization-level resource)
echo "Testing agent pools API..."
if ! agent_pools=$(az pipelines agent pool list --output json 2>agent_err.log); then
    err_msg=$(cat agent_err.log)
    rm -f agent_err.log
    
    health_json=$(echo "$health_json" | jq \
        --arg title "Agent Pools API Issue" \
        --arg details "Cannot access agent pools for organization $AZURE_DEVOPS_ORG: $err_msg" \
        --arg severity "3" \
        --arg next_steps "Check agent pool permissions and verify service principal has access to organization-level resources" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
else
    agent_pool_count=$(echo "$agent_pools" | jq '. | length')
    echo "Agent pools API: OK ($agent_pool_count pools found)"
fi
rm -f agent_err.log

# Test service connections API (requires project context, so test with first available project)
if [ "$project_count" -gt 0 ]; then
    first_project=$(echo "$org_info" | jq -r '.[0].name')
    echo "Testing service connections API with project: $first_project"
    
    if ! service_connections=$(az devops service-endpoint list --project "$first_project" --output json 2>service_err.log); then
        err_msg=$(cat service_err.log)
        rm -f service_err.log
        
        health_json=$(echo "$health_json" | jq \
            --arg title "Service Connections API Issue" \
            --arg details "Cannot access service connections: $err_msg" \
            --arg severity "2" \
            --arg next_steps "Check service connection permissions for the organization" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    else
        service_conn_count=$(echo "$service_connections" | jq '. | length')
        echo "Service connections API: OK ($service_conn_count connections found in $first_project)"
    fi
    rm -f service_err.log
fi

# Check for any rate limiting or throttling issues
echo "Checking for API rate limiting..."
start_time=$(date +%s)

# Make a few quick API calls to test for throttling
for i in {1..3}; do
    az devops project list --output table >/dev/null 2>&1 || true
    sleep 1
done

end_time=$(date +%s)
api_response_time=$((end_time - start_time))

if [ "$api_response_time" -gt 10 ]; then
    health_json=$(echo "$health_json" | jq \
        --arg title "Slow API Response Times" \
        --arg details "API calls are taking longer than expected (${api_response_time}s for basic operations)" \
        --arg severity "2" \
        --arg next_steps "Monitor for potential rate limiting or service performance issues" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
else
    echo "API response times: Normal (${api_response_time}s)"
fi

# Test organization settings access
echo "Testing organization settings access..."
if ! org_settings=$(az devops security group list --output json 2>settings_err.log); then
    err_msg=$(cat settings_err.log)
    rm -f settings_err.log
    
    # This is often a permissions issue, not necessarily a service health issue
    health_json=$(echo "$health_json" | jq \
        --arg title "Limited Organization Access" \
        --arg details "Cannot access organization settings: $err_msg" \
        --arg severity "1" \
        --arg next_steps "This may indicate limited permissions rather than a service issue. Consider granting additional organization-level permissions if needed." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
else
    echo "Organization settings access: OK"
fi
rm -f settings_err.log

# If no issues found, add a healthy status
if [ "$(echo "$health_json" | jq '. | length')" -eq 0 ]; then
    health_json=$(echo "$health_json" | jq \
        --arg title "Organization Service Health: Healthy" \
        --arg details "All Azure DevOps services are accessible and responding normally for organization $AZURE_DEVOPS_ORG" \
        --arg severity "1" \
        --arg next_steps "Continue monitoring. No action required." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Write final JSON
echo "$health_json" > "$OUTPUT_FILE"
echo "Organization service health check completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== SERVICE HEALTH SUMMARY ==="
echo "$health_json" | jq -r '.[] | "Status: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 