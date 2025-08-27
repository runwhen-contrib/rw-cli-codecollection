#!/bin/bash

set -o pipefail

# Environment variables
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}

ISSUES_FILE="network_config_issues.json"
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

echo "🌐 Analyzing ACR network configuration for registry: $ACR_NAME" >&2

# Set subscription context
az account set --subscription "$SUBSCRIPTION_ID" 2>/dev/null || {
    add_issue \
        "Failed to set Azure subscription context" \
        3 \
        "Should be able to set subscription context" \
        "Failed to set subscription $SUBSCRIPTION_ID" \
        "Subscription ID: $SUBSCRIPTION_ID" \
        "Verify subscription ID \`$SUBSCRIPTION_ID\` and Azure authentication for resource group \`$RESOURCE_GROUP\`" \
        "az account set --subscription $SUBSCRIPTION_ID"
    echo "❌ Failed to set subscription context" >&2
    cat "$ISSUES_FILE"
    exit 0
}

# Get ACR information
echo "📋 Retrieving ACR configuration..." >&2
acr_info=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" -o json 2>acr_show_err.log)
if [ $? -ne 0 ] || [ -z "$acr_info" ]; then
    error_details=$(cat acr_show_err.log 2>/dev/null || echo "Unknown error")
    
    add_issue \
        "Failed to retrieve ACR information" \
        3 \
        "Should be able to retrieve ACR details" \
        "az acr show command failed" \
        "Error: $error_details" \
        "Verify ACR name \`$ACR_NAME\`, resource group \`$RESOURCE_GROUP\`, and permissions" \
        "az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP"
    
    echo "❌ Failed to retrieve ACR information" >&2
    rm -f acr_show_err.log
    exit 0
fi

# Extract basic ACR details
login_server=$(echo "$acr_info" | jq -r '.loginServer // "Unknown"')
sku=$(echo "$acr_info" | jq -r '.sku.name // "Unknown"')
location=$(echo "$acr_info" | jq -r '.location // "Unknown"')
public_network_access=$(echo "$acr_info" | jq -r '.publicNetworkAccess // "Enabled"')
network_rule_bypass_options=$(echo "$acr_info" | jq -r '.networkRuleBypassOptions // "AzureServices"')

echo "🏢 Registry: $ACR_NAME ($login_server)" >&2
echo "📊 SKU: $sku" >&2
echo "🌍 Location: $location" >&2
echo "🌐 Public Network Access: $public_network_access" >&2
echo "🔄 Network Rule Bypass: $network_rule_bypass_options" >&2

# Check public network access configuration
if [ "$public_network_access" = "Disabled" ]; then
    echo "🔒 Public access is disabled - checking private endpoint configuration" >&2
    
    # Check for private endpoints
    private_endpoints=$(az network private-endpoint list --query "[?privateLinkServiceConnections[0].privateLinkServiceId==\`$(echo "$acr_info" | jq -r '.id')\`]" -o json 2>/dev/null)
    
    if [ -n "$private_endpoints" ] && [ "$private_endpoints" != "[]" ]; then
        pe_count=$(echo "$private_endpoints" | jq '. | length')
        echo "✅ Found $pe_count private endpoint(s)" >&2
        
        echo "$private_endpoints" | jq -r '.[] | "   - \(.name) in \(.resourceGroup) (\(.location))"' >&2
        
        # Check private endpoint status
        echo "$private_endpoints" | jq -c '.[]' | while read -r pe; do
            pe_name=$(echo "$pe" | jq -r '.name')
            pe_rg=$(echo "$pe" | jq -r '.resourceGroup')
            connection_state=$(echo "$pe" | jq -r '.privateLinkServiceConnections[0].privateLinkServiceConnectionState.status // "Unknown"')
            
            if [ "$connection_state" != "Approved" ]; then
                add_issue \
                    "Private endpoint connection not approved: $pe_name" \
                    2 \
                    "Private endpoint connections should be approved" \
                    "Private endpoint '$pe_name' has status: $connection_state" \
                    "Private endpoint: $pe_name, Resource group: $pe_rg, Status: $connection_state" \
                    "Approve the private endpoint connection for ACR \`$ACR_NAME\` in the Azure portal or using Azure CLI for resource group \`$RESOURCE_GROUP\`" \
                    "az network private-endpoint-connection approve --id <connection-id>"
            fi
        done
    else
        add_issue \
            "Public access disabled but no private endpoints found" \
            1 \
            "When public access is disabled, private endpoints should be configured" \
            "No private endpoints found for ACR with disabled public access" \
            "Public Network Access: $public_network_access, Private Endpoints: 0" \
            "Configure private endpoints to enable access to ACR \`$ACR_NAME\`, or enable public access with appropriate network rules in resource group \`$RESOURCE_GROUP\`" \
            "az network private-endpoint create --resource-group $RESOURCE_GROUP --name ${ACR_NAME}-pe --vnet-name <vnet> --subnet <subnet> --private-connection-resource-id $(echo '$acr_info' | jq -r '.id') --group-ids registry --connection-name ${ACR_NAME}-connection"
    fi
else
    echo "🌐 Public access is enabled - checking network access rules" >&2
fi

# Check network access rules
echo "🔍 Analyzing network access rules..." >&2
network_rule_set=$(az acr network-rule list --name "$ACR_NAME" -o json 2>/dev/null)

if [ -n "$network_rule_set" ]; then
    # Check IP rules
    ip_rules=$(echo "$network_rule_set" | jq '.ipRules // []')
    ip_rule_count=$(echo "$ip_rules" | jq '. | length')
    
    echo "📍 IP Rules: $ip_rule_count configured" >&2
    
    if [ "$ip_rule_count" -gt 0 ]; then
        echo "   Configured IP ranges:" >&2
        echo "$ip_rules" | jq -r '.[] | "   - \(.ipAddressOrRange) (Action: \(.action // "Allow"))"' >&2
        
        # Check for overly permissive rules
        overly_permissive=$(echo "$ip_rules" | jq -r '.[] | select(.ipAddressOrRange | test("0\\.0\\.0\\.0/0|::/0")) | .ipAddressOrRange')
        if [ -n "$overly_permissive" ]; then
            add_issue \
                "Overly permissive IP rule detected" \
                2 \
                "IP rules should be as restrictive as possible" \
                "Found rule allowing all IP addresses: $overly_permissive" \
                "IP rule allows access from any IP address: $overly_permissive" \
                "Replace broad IP rules for ACR \`$ACR_NAME\` with specific IP ranges or subnets that need access in resource group \`$RESOURCE_GROUP\`" \
                "az acr network-rule add --name $ACR_NAME --ip-address <specific-ip-range>"
        fi
    else
        if [ "$public_network_access" = "Enabled" ]; then
            add_issue \
                "No IP access rules configured with public access enabled" \
                3 \
                "When public access is enabled, IP rules should restrict access" \
                "Public access is enabled but no IP rules are configured" \
                "Public Network Access: Enabled, IP Rules: 0" \
                "Configure IP rules for ACR \`$ACR_NAME\` to restrict access to specific IP ranges or disable public access and use private endpoints in resource group \`$RESOURCE_GROUP\`" \
                "az acr network-rule add --name $ACR_NAME --ip-address <your-ip-range>"
        fi
    fi
    
    # Check virtual network rules
    vnet_rules=$(echo "$network_rule_set" | jq '.virtualNetworkRules // []')
    vnet_rule_count=$(echo "$vnet_rules" | jq '. | length')
    
    echo "🌐 Virtual Network Rules: $vnet_rule_count configured"
    
    if [ "$vnet_rule_count" -gt 0 ]; then
        echo "   Configured VNet rules:"
        echo "$vnet_rules" | jq -r '.[] | "   - \(.virtualNetworkResourceId | split("/") | .[-1]) (Action: \(.action // "Allow"))"'
    fi
    
    # Check default action
    default_action=$(echo "$network_rule_set" | jq -r '.defaultAction // "Allow"')
    echo "⚙️ Default Action: $default_action"
    
    if [ "$default_action" = "Allow" ] && [ "$public_network_access" = "Enabled" ]; then
        add_issue \
            "Default network action is Allow with public access enabled" \
            3 \
            "Default action should be Deny when using network rules for security" \
            "Default action is set to Allow" \
            "Default Action: Allow, Public Network Access: Enabled" \
            "Set default action to Deny for ACR \`$ACR_NAME\` and configure specific allow rules for required networks in resource group \`$RESOURCE_GROUP\`" \
            "az acr update --name $ACR_NAME --default-action Deny"
    fi
else
    echo "⚠️ Unable to retrieve network rules" >&2
fi

# Test DNS resolution
echo "🔍 Testing DNS resolution..." >&2
if command -v nslookup >/dev/null 2>&1; then
    dns_result=$(nslookup "$login_server" 2>&1)
    if echo "$dns_result" | grep -q "can't find\|NXDOMAIN\|No answer"; then
        add_issue \
            "DNS resolution failed for ACR login server" \
            2 \
            "ACR login server should resolve to valid IP addresses" \
            "DNS lookup failed for $login_server" \
            "DNS resolution error: $dns_result" \
            "Check DNS configuration, network connectivity, and private DNS zones if using private endpoints for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`" \
            "nslookup $login_server"
    else
        echo "✅ DNS resolution successful for $login_server" >&2
        # Extract and display IP addresses
        ips=$(echo "$dns_result" | grep -E "^Address: |^$login_server" | grep -v "#53" | awk '{print $2}' | tr '\n' ' ')
        if [ -n "$ips" ]; then
            echo "   Resolved IPs: $ips" >&2
        fi
    fi
else
    echo "ℹ️ nslookup not available - skipping DNS test"
fi

# Test basic connectivity
echo "🔗 Testing basic connectivity..." >&2
if command -v curl >/dev/null 2>&1; then
    # Test HTTPS connectivity (this should work even without authentication)
    connectivity_test=$(curl -s -I "https://$login_server/v2/" --max-time 10 2>&1)
    curl_exit_code=$?
    
    if [ $curl_exit_code -eq 0 ]; then
        echo "✅ HTTPS connectivity successful" >&2
        # Check if we get expected response (should be 401 Unauthorized for unauthenticated request)
        if echo "$connectivity_test" | grep -q "401 Unauthorized\|401"; then
            echo "✅ Expected authentication challenge received" >&2
        else
            echo "ℹ️ Unexpected response (may indicate network filtering):"
            echo "$connectivity_test" | head -3
        fi
    else
        case $curl_exit_code in
            6|7)
                add_issue \
                    "Network connectivity failed to ACR" \
                    2 \
                    "Should be able to connect to ACR login server" \
                    "Connection failed to https://$login_server (curl exit code: $curl_exit_code)" \
                    "Connectivity test failed with curl exit code $curl_exit_code" \
                    "Check network connectivity, firewall rules, and DNS resolution for ACR \`$ACR_NAME\`. Verify private endpoint configuration if public access is disabled in resource group \`$RESOURCE_GROUP\`." \
                    "curl -I https://$login_server/v2/"
                ;;
            28)
                add_issue \
                    "Connection timeout to ACR" \
                    2 \
                    "Connection should complete within reasonable time" \
                    "Connection timed out to https://$login_server" \
                    "Connection timeout after 10 seconds" \
                    "Check network latency, firewall rules, and routing for ACR \`$ACR_NAME\`. Consider network performance optimization in resource group \`$RESOURCE_GROUP\`." \
                    "curl -I https://$login_server/v2/ --max-time 30"
                ;;
            *)
                add_issue \
                    "Connectivity test failed" \
                    3 \
                    "Should be able to test connectivity to ACR" \
                    "Curl failed with exit code $curl_exit_code" \
                    "Curl error: $connectivity_test" \
                    "Investigate network connectivity issues for ACR \`$ACR_NAME\`, check firewall rules and DNS resolution in resource group \`$RESOURCE_GROUP\`" \
                    "curl -I https://$login_server/v2/"
                ;;
        esac
    fi
else
    echo "ℹ️ curl not available - skipping connectivity test"
fi

# Check for geo-replication (Premium SKU feature)
if [ "$sku" = "Premium" ]; then
    echo "🌍 Checking geo-replication configuration..."
    replications=$(az acr replication list --registry "$ACR_NAME" -o json 2>/dev/null)
    
    if [ -n "$replications" ] && [ "$replications" != "[]" ]; then
        replication_count=$(echo "$replications" | jq '. | length')
        echo "🌐 Geo-replications: $replication_count locations"
        
        echo "$replications" | jq -r '.[] | "   - \(.location) (Status: \(.provisioningState // "Unknown"))"'
        
        # Check for failed replications
        failed_replications=$(echo "$replications" | jq -r '.[] | select(.provisioningState != "Succeeded") | .location')
        if [ -n "$failed_replications" ]; then
            add_issue \
                "Failed geo-replication detected" \
                2 \
                "All geo-replications should be in Succeeded state" \
                "Found failed replications in: $(echo "$failed_replications" | tr '\n' ', ')" \
                "Failed replication locations: $failed_replications" \
                "Check replication status for ACR \`$ACR_NAME\` and resolve any networking or configuration issues in failed regions for resource group \`$RESOURCE_GROUP\`" \
                "az acr replication list --registry $ACR_NAME"
        fi
    else
        echo "ℹ️ No geo-replications configured (Premium feature)"
    fi
else
    echo "ℹ️ Geo-replication not available (requires Premium SKU)" >&2
fi

# Check webhook configuration
echo "🔗 Checking webhook configuration..." >&2
webhooks=$(az acr webhook list --registry "$ACR_NAME" -o json 2>/dev/null)

if [ -n "$webhooks" ] && [ "$webhooks" != "[]" ]; then
    webhook_count=$(echo "$webhooks" | jq '. | length')
    echo "🔗 Webhooks: $webhook_count configured"
    
    # Check webhook status and configuration
    echo "$webhooks" | jq -c '.[]' | while read -r webhook; do
        webhook_name=$(echo "$webhook" | jq -r '.name')
        webhook_status=$(echo "$webhook" | jq -r '.status // "Unknown"')
        service_uri=$(echo "$webhook" | jq -r '.serviceUri // "Unknown"')
        
        echo "   - $webhook_name: $webhook_status ($service_uri)"
        
        if [ "$webhook_status" != "enabled" ]; then
            add_issue \
                "Webhook not enabled: $webhook_name" \
                4 \
                "Configured webhooks should be enabled" \
                "Webhook '$webhook_name' has status: $webhook_status" \
                "Webhook: $webhook_name, Status: $webhook_status, URI: $service_uri" \
                "Enable the webhook for ACR \`$ACR_NAME\` or remove it if no longer needed in resource group \`$RESOURCE_GROUP\`" \
                "az acr webhook update --name $webhook_name --registry $ACR_NAME --status enabled"
        fi
        
        # Test webhook connectivity if it's enabled
        if [ "$webhook_status" = "enabled" ] && [ "$service_uri" != "Unknown" ] && command -v curl >/dev/null 2>&1; then
            webhook_test=$(curl -s -I "$service_uri" --max-time 5 2>&1)
            webhook_curl_exit=$?
            
            if [ $webhook_curl_exit -ne 0 ]; then
                add_issue \
                    "Webhook endpoint unreachable: $webhook_name" \
                    3 \
                    "Webhook endpoints should be reachable" \
                    "Cannot connect to webhook URI: $service_uri" \
                    "Webhook: $webhook_name, URI: $service_uri, Curl exit code: $webhook_curl_exit" \
                    "Verify webhook endpoint is accessible for ACR \`$ACR_NAME\`, check firewall rules and DNS resolution in resource group \`$RESOURCE_GROUP\`" \
                    "curl -I $service_uri"
            fi
        fi
    done
else
    echo "ℹ️ No webhooks configured" >&2
fi

# Generate troubleshooting information
echo "" >&2
echo "🔧 Network Troubleshooting Information:" >&2
echo "   1. Test connectivity: curl -I https://$login_server/v2/" >&2
echo "   2. Check DNS: nslookup $login_server" >&2
echo "   3. Test docker login: docker login $login_server" >&2
echo "   4. Check firewall rules for ports 443 (HTTPS)" >&2

if [ "$public_network_access" = "Disabled" ]; then
    echo "   5. Verify private endpoint DNS resolution"
    echo "   6. Check private endpoint connection status"
    echo "   7. Verify subnet and VNet configuration"
fi

# Generate portal URLs
resource_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
portal_url="https://portal.azure.com/#@/resource$resource_id"

echo "" >&2
echo "🔗 Portal URLs:" >&2
echo "   ACR Overview: $portal_url" >&2
echo "   Networking: ${portal_url}/networking" >&2
echo "   Private Endpoints: ${portal_url}/privateEndpointConnections" >&2
if [ "$sku" = "Premium" ]; then
    echo "   Geo-replication: ${portal_url}/replications"
fi
echo "   Webhooks: ${portal_url}/webhooks" >&2

# Clean up temporary files
rm -f acr_show_err.log

echo "" >&2
echo "✅ Network configuration analysis complete" >&2

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE"

# Display summary
issue_count=$(jq '. | length' "$ISSUES_FILE")
echo "📋 Issues found: $issue_count" >&2

if [ "$issue_count" -gt 0 ]; then
    echo "" >&2
    echo "Issues:" >&2
    jq -r '.[] | "  - \(.title) (Severity: \(.severity))"' "$ISSUES_FILE"
fi
