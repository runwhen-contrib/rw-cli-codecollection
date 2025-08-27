#!/bin/bash

set -o pipefail

# Environment variables
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}

ISSUES_FILE="resource_health_issues.json"
echo '[]' > "$ISSUES_FILE"

add_issue() {
    local title="$1"
    local severity="$2"
    local expected="$3"
    local actual="$4"
    local details="$5"
    local next_steps="$6"
    local reproduce_hint="$7"
    
    # Escape JSON characters properly
    details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    next_steps=$(echo "$next_steps" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    reproduce_hint=$(echo "$reproduce_hint" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    local issue="{\"title\":\"$title\",\"severity\":$severity,\"expected\":\"$expected\",\"actual\":\"$actual\",\"details\":\"$details\",\"next_steps\":\"$next_steps\",\"reproduce_hint\":\"$reproduce_hint\"}"
    jq ". += [${issue}]" "$ISSUES_FILE" > temp.json && mv temp.json "$ISSUES_FILE"
}

# Validate required environment variables
if [ -z "$SUBSCRIPTION_ID" ] || [ -z "$RESOURCE_GROUP" ] || [ -z "$ACR_NAME" ]; then
    missing_vars=()
    [ -z "$SUBSCRIPTION_ID" ] && missing_vars+=("AZURE_SUBSCRIPTION_ID")
    [ -z "$RESOURCE_GROUP" ] && missing_vars+=("AZ_RESOURCE_GROUP")
    [ -z "$ACR_NAME" ] && missing_vars+=("ACR_NAME")
    
    add_issue \
        "Missing required environment variables" \
        4 \
        "All required environment variables should be set" \
        "Missing variables: ${missing_vars[*]}" \
        "Required variables: AZURE_SUBSCRIPTION_ID, AZ_RESOURCE_GROUP, ACR_NAME" \
        "Set the missing environment variables and retry" \
        "Check environment variable configuration"
    
    echo "❌ Missing required environment variables: ${missing_vars[*]}" >&2
    
    # Still output JSON even when there are missing variables
    cat "$ISSUES_FILE"
    exit 0
fi

echo "🏥 Checking Azure Resource Health for ACR: $ACR_NAME" >&2

# Set subscription context
az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null || {
    add_issue \
        "Failed to set Azure subscription context" \
        3 \
        "Should be able to set subscription context" \
        "Failed to set subscription $SUBSCRIPTION_ID" \
        "Attempted to set Azure subscription context for ACR health check. Command: 'az account set --subscription $SUBSCRIPTION_ID'. This failure prevents accessing Azure Resource Health API for ACR '$ACR_NAME' in resource group '$RESOURCE_GROUP'. Common causes: invalid subscription ID, insufficient permissions, or Azure CLI not authenticated." \
        "Verify subscription ID \`$SUBSCRIPTION_ID\` and Azure authentication for resource group \`$RESOURCE_GROUP\`" \
        "az account set --subscription $SUBSCRIPTION_ID"
    echo "❌ Failed to set subscription context" >&2
    cat "$ISSUES_FILE"
    exit 0
}

# Check if Microsoft.ResourceHealth provider is registered
echo "🔍 Checking Microsoft.ResourceHealth provider registration..." >&2
provider_state=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv 2>/dev/null)

if [ "$provider_state" != "Registered" ]; then
    echo "📋 Microsoft.ResourceHealth provider not registered (State: $provider_state)" >&2
    
    if [ "$provider_state" = "NotRegistered" ]; then
        echo "🔄 Attempting to register Microsoft.ResourceHealth provider..." >&2
        az provider register --namespace Microsoft.ResourceHealth 2>/dev/null || {
            add_issue \
                "Failed to register Microsoft.ResourceHealth provider" \
                3 \
                "Microsoft.ResourceHealth provider should be registered" \
                "Provider registration failed" \
                "Provider state: $provider_state" \
                "Manually register the Microsoft.ResourceHealth provider for subscription \`$SUBSCRIPTION_ID\`: az provider register --namespace Microsoft.ResourceHealth" \
                "az provider register --namespace Microsoft.ResourceHealth"
            echo "❌ Failed to register provider" >&2
        }
        
        # Wait for registration to complete (up to 60 seconds)
        for i in {1..12}; do
            sleep 5
            current_state=$(az provider show --namespace Microsoft.ResourceHealth --query "registrationState" -o tsv 2>/dev/null)
            if [ "$current_state" = "Registered" ]; then
                echo "✅ Microsoft.ResourceHealth provider registered successfully" >&2
                provider_state="Registered"
                break
            fi
            echo "⏳ Waiting for provider registration... (attempt $i/12, state: $current_state)" >&2
        done
        
        if [ "$provider_state" != "Registered" ]; then
            add_issue \
                "Microsoft.ResourceHealth provider registration incomplete" \
                3 \
                "Provider should be registered to access resource health data" \
                "Provider registration is taking longer than expected (state: $current_state)" \
                "Current state: $current_state" \
                "Wait for Microsoft.ResourceHealth provider registration to complete for subscription \`$SUBSCRIPTION_ID\`, or contact Azure support if it remains stuck" \
                "az provider show --namespace Microsoft.ResourceHealth"
        fi
    else
        add_issue \
            "Microsoft.ResourceHealth provider in unexpected state" \
            3 \
            "Provider should be registered" \
            "Provider state is $provider_state" \
            "Expected: Registered, Actual: $provider_state" \
            "Check Microsoft.ResourceHealth provider registration status for subscription \`$SUBSCRIPTION_ID\` and re-register if needed" \
            "az provider register --namespace Microsoft.ResourceHealth"
    fi
else
    echo "✅ Microsoft.ResourceHealth provider is registered" >&2
fi

# Get ACR resource ID
acr_resource_id=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" --query "id" -o tsv 2>/dev/null)
if [ -z "$acr_resource_id" ]; then
    add_issue \
        "Failed to retrieve ACR resource ID" \
        3 \
        "Should be able to retrieve ACR resource information" \
        "ACR resource ID not found" \
        "Attempted to retrieve ACR resource ID for health monitoring using command: 'az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query id -o tsv'. This is required to query Azure Resource Health API. Failure indicates: ACR '$ACR_NAME' may not exist in resource group '$RESOURCE_GROUP', insufficient permissions to read ACR properties, or network connectivity issues." \
        "Verify ACR name \`$ACR_NAME\`, resource group \`$RESOURCE_GROUP\`, and permissions" \
        "az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP"
    echo "❌ Failed to retrieve ACR resource ID" >&2
    cat "$ISSUES_FILE"
    exit 0
fi

echo "📋 ACR Resource ID: $acr_resource_id" >&2

# Query current resource health status using REST API
echo "🏥 Querying current resource health status..." >&2
health_url="https://management.azure.com${acr_resource_id}/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=2023-07-01-preview"

# Get access token
access_token=$(az account get-access-token --query "accessToken" -o tsv 2>/dev/null)
if [ -z "$access_token" ]; then
    add_issue \
        "Failed to obtain Azure access token" \
        3 \
        "Should be able to obtain access token for API calls" \
        "Access token retrieval failed" \
        "Required for Resource Health API access" \
        "Check Azure authentication and permissions for subscription \`$SUBSCRIPTION_ID\` and resource group \`$RESOURCE_GROUP\`" \
        "az account get-access-token"
    echo "❌ Failed to obtain access token" >&2
    cat "$ISSUES_FILE"
    exit 0
fi

# Make REST API call to get resource health
health_response=$(curl -s -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" "$health_url" 2>/dev/null)
curl_exit_code=$?

if [ $curl_exit_code -ne 0 ] || [ -z "$health_response" ]; then
    add_issue \
        "Failed to query Resource Health API" \
        3 \
        "Should be able to query Resource Health status" \
        "Resource Health API call failed" \
        "API URL: $health_url, Curl exit code: $curl_exit_code" \
        "Check network connectivity and API permissions for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`" \
        "curl -H \"Authorization: Bearer \$TOKEN\" $health_url"
    echo "❌ Failed to query Resource Health API" >&2
    cat "$ISSUES_FILE"
    exit 0
fi

# Check if response contains error
if echo "$health_response" | jq -e '.error' >/dev/null 2>&1; then
    error_code=$(echo "$health_response" | jq -r '.error.code // "Unknown"')
    error_message=$(echo "$health_response" | jq -r '.error.message // "Unknown error"')
    
    add_issue \
        "Resource Health API returned error" \
        3 \
        "Resource Health API should return valid health data" \
        "API error: $error_code - $error_message" \
        "Error code: $error_code, Message: $error_message" \
        "Check API permissions and resource health provider registration for ACR \`$ACR_NAME\` in subscription \`$SUBSCRIPTION_ID\`" \
        "Verify Microsoft.ResourceHealth provider is registered and permissions are correct"
    
    echo "❌ Resource Health API error: $error_code - $error_message" >&2
    cat "$ISSUES_FILE"
    exit 0
fi

# Parse health status
if echo "$health_response" | jq -e '.properties' >/dev/null 2>&1; then
    availability_state=$(echo "$health_response" | jq -r '.properties.availabilityState // "Unknown"')
    detailed_status=$(echo "$health_response" | jq -r '.properties.detailedStatus // "Unknown"')
    reason_type=$(echo "$health_response" | jq -r '.properties.reasonType // "Unknown"')
    occurred_time=$(echo "$health_response" | jq -r '.properties.occurredTime // "Unknown"')
    reason_chronicity=$(echo "$health_response" | jq -r '.properties.reasonChronicity // "Unknown"')
    reported_time=$(echo "$health_response" | jq -r '.properties.reportedTime // "Unknown"')
    
    echo "📊 Resource Health Status:" >&2
    echo "   Availability State: $availability_state" >&2
    echo "   Detailed Status: $detailed_status" >&2
    echo "   Reason Type: $reason_type" >&2
    echo "   Reason Chronicity: $reason_chronicity" >&2
    echo "   Occurred Time: $occurred_time" >&2
    echo "   Reported Time: $reported_time" >&2
    
    # Analyze health status and create issues
    case "$availability_state" in
        "Available")
            echo "✅ ACR is available and healthy" >&2
            ;;
        "Unavailable")
            add_issue \
                "ACR is currently unavailable" \
                1 \
                "ACR should be available for normal operations" \
                "Current availability state is Unavailable" \
                "State: $availability_state, Reason: $reason_type, Details: $detailed_status, Occurred: $occurred_time" \
                "This is a critical issue for ACR \`$ACR_NAME\`. Check Azure status page, contact Azure support, and verify network connectivity in resource group \`$RESOURCE_GROUP\`" \
                "Check Azure status and contact support immediately"
            ;;
        "Degraded")
            add_issue \
                "ACR performance is degraded" \
                2 \
                "ACR should operate at full performance" \
                "Current availability state is Degraded" \
                "State: $availability_state, Reason: $reason_type, Details: $detailed_status, Occurred: $occurred_time" \
                "Monitor ACR \`$ACR_NAME\` performance closely, check for increased latency or errors, and consider Azure support if issues persist in resource group \`$RESOURCE_GROUP\`" \
                "Monitor metrics and consider contacting Azure support"
            ;;
        "Unknown")
            add_issue \
                "ACR health status is unknown" \
                3 \
                "Resource health status should be determinable" \
                "Current availability state is Unknown" \
                "State: $availability_state, Reason: $reason_type, Details: $detailed_status" \
                "This may indicate monitoring issues or recent service changes for ACR \`$ACR_NAME\`. Monitor ACR functionality and check back later in resource group \`$RESOURCE_GROUP\`" \
                "Monitor ACR operations and check health status again later"
            ;;
        *)
            add_issue \
                "Unexpected ACR health status" \
                3 \
                "Health status should be Available, Unavailable, Degraded, or Unknown" \
                "Unexpected availability state: $availability_state" \
                "State: $availability_state, Reason: $reason_type, Details: $detailed_status" \
                "Contact Azure support for clarification on this unexpected status for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`" \
                "Contact Azure support for status clarification"
            ;;
    esac
    
    # Check reason type for additional insights
    case "$reason_type" in
        "PlatformInitiated")
            if [ "$availability_state" != "Available" ]; then
                add_issue \
                    "Azure platform initiated health change" \
                    2 \
                    "Platform should maintain service availability" \
                    "Platform-initiated change caused $availability_state state" \
                    "Reason: Platform-initiated, State: $availability_state, Chronicity: $reason_chronicity" \
                    "This indicates Azure platform maintenance or issues for ACR \`$ACR_NAME\`. Check Azure status page and service health notifications for resource group \`$RESOURCE_GROUP\`" \
                    "Check Azure Service Health dashboard"
            fi
            ;;
        "UserInitiated")
            echo "ℹ️ Health change was user-initiated (expected during maintenance operations)" >&2
            ;;
        "Unknown")
            if [ "$availability_state" != "Available" ]; then
                add_issue \
                    "Unknown cause for health status change" \
                    3 \
                    "Reason for health changes should be identifiable" \
                    "Unknown reason for $availability_state state" \
                    "State: $availability_state, Reason: Unknown" \
                    "Monitor ACR \`$ACR_NAME\` closely and contact Azure support if issues persist in resource group \`$RESOURCE_GROUP\`" \
                    "Monitor and contact support if needed"
            fi
            ;;
    esac
    
    # Save detailed health information for reference
    echo "$health_response" > "acr_resource_health_details.json"
    echo "💾 Detailed health information saved to acr_resource_health_details.json" >&2
    
else
    add_issue \
        "Invalid Resource Health API response" \
        3 \
        "Resource Health API should return valid health properties" \
        "API response missing expected properties" \
        "Response: $health_response" \
        "Check API response format for ACR \`$ACR_NAME\` and contact Azure support if issue persists in resource group \`$RESOURCE_GROUP\`" \
        "Verify Resource Health API response format"
    
    echo "❌ Invalid Resource Health API response" >&2
fi

# Query historical health events (last 30 days)
echo "📅 Querying historical health events..." >&2
history_url="https://management.azure.com${acr_resource_id}/providers/Microsoft.ResourceHealth/availabilityStatuses?api-version=2023-07-01-preview&\$filter=occurredTime ge $(date -u -d '30 days ago' '+%Y-%m-%dT%H:%M:%SZ')"

history_response=$(curl -s -H "Authorization: Bearer $access_token" -H "Content-Type: application/json" "$history_url" 2>/dev/null)
history_curl_exit=$?

if [ $history_curl_exit -eq 0 ] && [ -n "$history_response" ] && ! echo "$history_response" | jq -e '.error' >/dev/null 2>&1; then
    history_count=$(echo "$history_response" | jq '.value | length' 2>/dev/null || echo "0")
    echo "📊 Historical events (last 30 days): $history_count" >&2
    
    if [ "$history_count" -gt 0 ]; then
        # Count different types of events
        unavailable_events=$(echo "$history_response" | jq '[.value[] | select(.properties.availabilityState == "Unavailable")] | length')
        degraded_events=$(echo "$history_response" | jq '[.value[] | select(.properties.availabilityState == "Degraded")] | length')
        
        echo "   Unavailable events: $unavailable_events" >&2
        echo "   Degraded events: $degraded_events" >&2
        
        # Alert on frequent issues
        if [ "$unavailable_events" -gt 3 ]; then
            add_issue \
                "Frequent unavailability events detected" \
                2 \
                "ACR should maintain high availability" \
                "Found $unavailable_events unavailable events in the last 30 days" \
                "Unavailable events: $unavailable_events in 30 days" \
                "Investigate recurring availability issues, check for patterns, and consider Azure support engagement" \
                "Review historical health data and contact Azure support"
        fi
        
        if [ "$degraded_events" -gt 5 ]; then
            add_issue \
                "Frequent performance degradation detected" \
                3 \
                "ACR should maintain consistent performance" \
                "Found $degraded_events degraded performance events in the last 30 days" \
                "Degraded events: $degraded_events in 30 days" \
                "Monitor ACR performance metrics and consider performance optimization or Azure support consultation" \
                "Review performance metrics and consider support consultation"
        fi
        
        # Show recent significant events
        recent_issues=$(echo "$history_response" | jq -r '.value[] | select(.properties.availabilityState != "Available") | select(.properties.occurredTime > "'$(date -u -d '7 days ago' '+%Y-%m-%dT%H:%M:%SZ')'") | "\(.properties.occurredTime): \(.properties.availabilityState) - \(.properties.reasonType)"' | head -5)
        
        if [ -n "$recent_issues" ]; then
            echo "   Recent issues (last 7 days):" >&2
            echo "$recent_issues" | sed 's/^/     /' >&2
        fi
        
        # Save historical data
        echo "$history_response" > "acr_resource_health_history.json"
        echo "💾 Historical health data saved to acr_resource_health_history.json" >&2
    else
        echo "✅ No health issues detected in the last 30 days" >&2
    fi
else
    echo "⚠️ Unable to retrieve historical health data" >&2
    add_issue \
        "Failed to retrieve historical health data" \
        4 \
        "Should be able to query historical health events" \
        "Historical health query failed" \
        "Unable to retrieve 30-day health history" \
        "This is informational only. Current health status is still available." \
        "Check network connectivity and API permissions"
fi

# Generate portal URLs
resource_id_encoded=$(echo "$acr_resource_id" | sed 's|/|%2F|g')
portal_url="https://portal.azure.com/#@/resource$acr_resource_id"
health_url_portal="https://portal.azure.com/#@/resource$acr_resource_id/resourceHealth"

echo "" >&2
echo "🔗 Portal URLs:" >&2
echo "   ACR Overview: $portal_url" >&2
echo "   Resource Health: $health_url_portal" >&2
echo "   Service Health: https://portal.azure.com/#blade/Microsoft_Azure_Health/AzureHealthBrowseBlade" >&2

echo "" >&2
echo "📋 Resource Health Summary:" >&2
if [ -n "$availability_state" ]; then
    echo "   Current Status: $availability_state" >&2
    if [ -n "$detailed_status" ] && [ "$detailed_status" != "Unknown" ]; then
        echo "   Details: $detailed_status" >&2
    fi
    if [ -n "$occurred_time" ] && [ "$occurred_time" != "Unknown" ]; then
        echo "   Last Change: $occurred_time" >&2
    fi
else
    echo "   Status: Unable to determine" >&2
fi

echo "" >&2
echo "✅ Resource health analysis complete" >&2

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE"

# Display summary
issue_count=$(jq '. | length' "$ISSUES_FILE")
echo "📋 Issues found: $issue_count" >&2

if [ "$issue_count" -gt 0 ]; then
    echo "" >&2
    echo "Issues:" >&2
    jq -r '.[] | "  - \(.title) (Severity: \(.severity))"' "$ISSUES_FILE" >&2
fi
