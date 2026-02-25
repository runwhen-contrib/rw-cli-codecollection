#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   AUTH_TYPE (optional, default: service_principal)
#   AZURE_DEVOPS_PAT (required if AUTH_TYPE=pat)
#
# This script:
#   1) Checks for Azure DevOps service incidents
#   2) Monitors service health status
#   3) Correlates local issues with known service problems
#   4) Provides incident context for troubleshooting
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${AUTH_TYPE:=service_principal}"

OUTPUT_FILE="service_incident_check.json"
incident_json='[]'

echo "Checking for Azure DevOps Service Incidents..."
echo "Organization: $AZURE_DEVOPS_ORG"

# Setup authentication (if needed for Azure CLI commands later)
if [ "$AUTH_TYPE" = "service_principal" ]; then
    echo "Using service principal authentication..."
    # Service principal authentication is handled by Azure CLI login
elif [ "$AUTH_TYPE" = "pat" ]; then
    if [ -z "${AZURE_DEVOPS_PAT:-}" ]; then
        echo "ERROR: AZURE_DEVOPS_PAT must be set when AUTH_TYPE=pat"
        exit 1
    fi
    echo "Using PAT authentication..."
    # We'll setup PAT auth later if needed for specific commands
else
    echo "ERROR: Invalid AUTH_TYPE. Must be 'service_principal' or 'pat'"
    exit 1
fi

# Check Azure DevOps service status (using public status page approach)
echo "Checking Azure DevOps service status..."

# Test basic connectivity and response times to Azure DevOps
echo "Testing Azure DevOps connectivity..."
devops_url="https://dev.azure.com/$AZURE_DEVOPS_ORG"
status_url="https://status.dev.azure.com"

# Test connectivity to organization
start_time=$(date +%s)
if response=$(curl -s -w "%{http_code},%{time_total}" -o /dev/null "$devops_url" 2>/dev/null); then
    http_code=$(echo "$response" | cut -d',' -f1)
    response_time=$(echo "$response" | cut -d',' -f2)
    end_time=$(date +%s)
    
    echo "Organization URL response: HTTP $http_code, ${response_time}s"
    
    if [ "$http_code" -ne 200 ] && [ "$http_code" -ne 302 ]; then
        incident_json=$(echo "$incident_json" | jq \
            --arg title "Azure DevOps Organization Connectivity Issue" \
            --arg details "Organization URL returned HTTP $http_code instead of expected 200/302" \
            --arg severity "4" \
            --arg next_steps "Check Azure DevOps service status and verify organization URL accessibility" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
    
    # Check if response time is unusually slow
    if (( $(echo "$response_time > 5.0" | bc -l 2>/dev/null || echo "0") )); then
        incident_json=$(echo "$incident_json" | jq \
            --arg title "Slow Azure DevOps Response Times" \
            --arg details "Organization URL response time is ${response_time}s (>5s threshold)" \
            --arg severity "2" \
            --arg next_steps "Monitor Azure DevOps service performance and check for regional issues" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
else
    incident_json=$(echo "$incident_json" | jq \
        --arg title "Cannot Connect to Azure DevOps Organization" \
        --arg details "Failed to connect to organization URL: $devops_url" \
        --arg severity "4" \
        --arg next_steps "Check network connectivity and Azure DevOps service availability" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Test Azure DevOps status page connectivity
echo "Checking Azure DevOps status page..."
if status_response=$(curl -s -w "%{http_code}" -o status_page.html "$status_url" 2>/dev/null); then
    status_code=$(echo "$status_response" | tail -c 4)
    
    if [ "$status_code" = "200" ]; then
        echo "Status page accessible"
        
        # Parse actual service status from JSON data instead of keyword search
        if service_status=$(grep -o '"serviceStatus":{[^}]*"health":[0-9]*[^}]*}' status_page.html 2>/dev/null); then
            # Extract health status (1=healthy, 2=advisory, 3=degraded, 4=unhealthy)
            health_status=$(echo "$service_status" | grep -o '"health":[0-9]*' | cut -d':' -f2)
            service_message=$(echo "$service_status" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
            
            if [ "$health_status" -le 2 ]; then
                # Health status 1-2 indicates degraded or unhealthy services
                incident_json=$(echo "$incident_json" | jq \
                    --arg title "Azure DevOps Service Degradation Detected" \
                    --arg details "Service health status: $health_status. Message: $service_message" \
                    --arg severity "3" \
                    --arg next_steps "Check Azure DevOps status page for current incidents and service advisories" \
                    '. += [{
                       "title": $title,
                       "details": $details,
                       "severity": ($severity | tonumber),
                       "next_steps": $next_steps
                     }]')
            else
                echo "Azure DevOps services report healthy status (health: $health_status)"
            fi
        else
            echo "Could not parse service status from status page"
        fi
    else
        echo "Status page returned HTTP $status_code"
    fi
else
    echo "Could not access Azure DevOps status page"
fi

# Clean up temporary file
rm -f status_page.html

# Check Azure CLI connectivity and authentication
echo "Testing Azure CLI connectivity..."
cli_start=$(date +%s)
if az account show >/dev/null 2>&1; then
    cli_end=$(date +%s)
    cli_duration=$((cli_end - cli_start))
    
    echo "Azure CLI authentication: OK (${cli_duration}s)"
    
    if [ "$cli_duration" -gt 10 ]; then
        incident_json=$(echo "$incident_json" | jq \
            --arg title "Slow Azure Authentication" \
            --arg details "Azure CLI authentication took ${cli_duration}s (>10s threshold)" \
            --arg severity "2" \
            --arg next_steps "Check Azure Active Directory service status and network connectivity" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
else
    incident_json=$(echo "$incident_json" | jq \
        --arg title "Azure CLI Authentication Failed" \
        --arg details "Cannot authenticate with Azure CLI - may indicate Azure AD or credential issues" \
        --arg severity "4" \
        --arg next_steps "Check Azure CLI configuration, service principal credentials, and Azure AD service status" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Test Azure DevOps API endpoints
echo "Testing Azure DevOps API endpoints..."
api_endpoints=(
    "https://dev.azure.com/$AZURE_DEVOPS_ORG/_apis/projects"
    "https://dev.azure.com/$AZURE_DEVOPS_ORG/_apis/distributedtask/pools"
)

for endpoint in "${api_endpoints[@]}"; do
    endpoint_name=$(basename "$endpoint")
    echo "  Testing endpoint: $endpoint_name"
    
    if api_response=$(curl -s -w "%{http_code},%{time_total}" -o /dev/null "$endpoint" 2>/dev/null); then
        api_code=$(echo "$api_response" | cut -d',' -f1)
        api_time=$(echo "$api_response" | cut -d',' -f2)
        
        echo "    Response: HTTP $api_code, ${api_time}s"
        
        # 401 is expected without authentication, 302 is normal redirect, 200/203 are success
        if [ "$api_code" != "401" ] && [ "$api_code" != "200" ] && [ "$api_code" != "302" ] && [ "$api_code" != "203" ]; then
            incident_json=$(echo "$incident_json" | jq \
                --arg title "Azure DevOps API Endpoint Issue" \
                --arg details "API endpoint $endpoint_name returned HTTP $api_code" \
                --arg severity "3" \
                --arg next_steps "Check Azure DevOps API service status and endpoint availability" \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "severity": ($severity | tonumber),
                   "next_steps": $next_steps
                 }]')
        fi
        
        if (( $(echo "$api_time > 10.0" | bc -l 2>/dev/null || echo "0") )); then
            incident_json=$(echo "$incident_json" | jq \
                --arg title "Slow Azure DevOps API Response" \
                --arg details "API endpoint $endpoint_name response time is ${api_time}s" \
                --arg severity "2" \
                --arg next_steps "Monitor Azure DevOps API performance and check for service degradation" \
                '. += [{
                   "title": $title,
                   "details": $details,
                   "severity": ($severity | tonumber),
                   "next_steps": $next_steps
                 }]')
        fi
    else
        incident_json=$(echo "$incident_json" | jq \
            --arg title "Cannot Reach Azure DevOps API" \
            --arg details "Failed to connect to API endpoint: $endpoint_name" \
            --arg severity "4" \
            --arg next_steps "Check network connectivity and Azure DevOps API service availability" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
done

# Check Azure DevOps specific connectivity instead of generic internet
echo "Checking Azure DevOps specific connectivity..."
azure_targets=("dev.azure.com" "status.dev.azure.com")
failed_azure_connections=0

for target in "${azure_targets[@]}"; do
    if ! curl -s --connect-timeout 10 "https://$target" >/dev/null 2>&1; then
        failed_azure_connections=$((failed_azure_connections + 1))
    fi
done

if [ "$failed_azure_connections" -gt 0 ]; then
    incident_json=$(echo "$incident_json" | jq \
        --arg title "Azure DevOps Connectivity Issues" \
        --arg details "Cannot reach $failed_azure_connections Azure DevOps endpoints - may indicate service or network issues" \
        --arg severity "4" \
        --arg next_steps "Check Azure DevOps service status and local network connectivity to Azure endpoints" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
fi

# Check system time synchronization (important for authentication)
echo "Checking system time synchronization..."
if command -v timedatectl >/dev/null 2>&1; then
    if ! timedatectl status | grep -q "synchronized: yes"; then
        incident_json=$(echo "$incident_json" | jq \
            --arg title "System Time Not Synchronized" \
            --arg details "System time may not be synchronized, which can cause authentication issues" \
            --arg severity "2" \
            --arg next_steps "Synchronize system time using NTP to prevent authentication failures" \
            '. += [{
               "title": $title,
               "details": $details,
               "severity": ($severity | tonumber),
               "next_steps": $next_steps
             }]')
    fi
fi

# Only report if there are actual incidents - don't create issues for healthy status
if [ "$(echo "$incident_json" | jq '. | length')" -eq 0 ]; then
    echo "No service incidents detected - Azure DevOps services appear healthy"
fi

# Write final JSON
echo "$incident_json" > "$OUTPUT_FILE"
echo "Service incident check completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== SERVICE INCIDENT CHECK SUMMARY ==="
echo "$incident_json" | jq -r '.[] | "Status: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 