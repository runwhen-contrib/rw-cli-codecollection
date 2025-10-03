#!/bin/bash

# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

set -o pipefail

# Environment variables
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}

ISSUES_FILE="rbac_security_issues.json"
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
    cat "$ISSUES_FILE"
    exit 0
fi

echo "🔐 Analyzing ACR security configuration for registry: $ACR_NAME" >&2
echo "📋 Subscription: $SUBSCRIPTION_ID" >&2
echo "📁 Resource Group: $RESOURCE_GROUP" >&2

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

# Get ACR resource information
echo "📋 Retrieving ACR information..." >&2
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
    cat "$ISSUES_FILE"
    exit 0
fi

# Extract ACR details
resource_id=$(echo "$acr_info" | jq -r '.id')
sku=$(echo "$acr_info" | jq -r '.sku.name // "Unknown"')
login_server=$(echo "$acr_info" | jq -r '.loginServer // "Unknown"')
admin_enabled=$(echo "$acr_info" | jq -r '.adminUserEnabled // false')
public_access=$(echo "$acr_info" | jq -r '.publicNetworkAccess // "Enabled"')

echo "🏢 Registry: $ACR_NAME ($login_server)" >&2
echo "📊 SKU: $sku" >&2
echo "🔑 Admin user enabled: $admin_enabled" >&2
echo "🌐 Public network access: $public_access" >&2

# 1. Check Admin User Status
echo "🔍 Checking admin user configuration..." >&2
if [ "$admin_enabled" = "true" ]; then
    add_issue \
        "Admin user is enabled for ACR" \
        2 \
        "Admin user should be disabled for security best practices" \
        "Admin user is currently enabled" \
        "Admin user provides username/password authentication which is less secure than RBAC or service principal authentication. Registry: $ACR_NAME, Admin Enabled: $admin_enabled" \
        "Disable admin user for ACR \`$ACR_NAME\` with 'az acr update --admin-enabled false' and use RBAC or service principal authentication instead for resource group \`$RESOURCE_GROUP\`" \
        "az acr update --name $ACR_NAME --admin-enabled false"
fi

# 2. Check Public Network Access
echo "🌐 Checking public network access..." >&2
if [ "$public_access" = "Enabled" ]; then
    # This is informational - not necessarily a security issue, but worth noting
    echo "ℹ️ Public network access is enabled. Consider private endpoints for enhanced security." >&2
    
    # Check if there are any network access rules for Premium SKUs
    if [ "$sku" = "Premium" ]; then
        network_rules=$(echo "$acr_info" | jq -r '.networkRuleSet // empty')
        if [ -n "$network_rules" ]; then
            default_action=$(echo "$network_rules" | jq -r '.defaultAction // "Allow"')
            ip_rules_count=$(echo "$network_rules" | jq -r '.ipRules | length // 0')
            vnet_rules_count=$(echo "$network_rules" | jq -r '.virtualNetworkRules | length // 0')
            
            echo "🔒 Network rules configured: Default=$default_action, IP rules=$ip_rules_count, VNet rules=$vnet_rules_count" >&2
            
            if [ "$default_action" = "Allow" ] && [ "$ip_rules_count" -eq 0 ] && [ "$vnet_rules_count" -eq 0 ]; then
                add_issue \
                    "Public access enabled without network restrictions" \
                    3 \
                    "When public access is enabled, network access rules should restrict access" \
                    "Public access is enabled with no IP or VNet restrictions" \
                    "Registry allows access from any public IP address. Default action: $default_action, IP rules: $ip_rules_count, VNet rules: $vnet_rules_count" \
                    "Configure network access rules for ACR \`$ACR_NAME\` to restrict access from specific IP ranges or VNets, or consider using private endpoints in resource group \`$RESOURCE_GROUP\`" \
                    "az acr network-rule add --name $ACR_NAME --ip-address <your-ip-range>"
            fi
        else
            add_issue \
                "Premium ACR without network access rules" \
                3 \
                "Premium ACR should have network access rules configured for security" \
                "No network access rules configured despite Premium SKU" \
                "Premium SKU supports network access rules but none are configured. This allows unrestricted public access." \
                "Configure network access rules for ACR \`$ACR_NAME\` to restrict access from specific IP ranges or VNets, or disable public access and use private endpoints for resource group \`$RESOURCE_GROUP\`" \
                "az acr network-rule add --name $ACR_NAME --ip-address <your-ip-range>"
        fi
    fi
else
    echo "✅ Public network access is disabled" >&2
fi

# 3. Check RBAC assignments
echo "🔍 Checking RBAC assignments..." >&2
rbac_assignments=$(az role assignment list --scope "$resource_id" -o json 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$rbac_assignments" ]; then
    rbac_count=$(echo "$rbac_assignments" | jq '. | length')
    echo "📊 Found $rbac_count RBAC assignments" >&2
    
    if [ "$rbac_count" -eq 0 ]; then
        add_issue \
            "No RBAC assignments found for ACR" \
            4 \
            "ACR should have appropriate RBAC assignments for access control" \
            "No RBAC assignments configured" \
            "Without RBAC assignments, access control relies on admin user or less secure authentication methods" \
            "Configure appropriate RBAC assignments for ACR \`$ACR_NAME\` such as AcrPull, AcrPush, or AcrDelete roles for users, service principals, or managed identities in resource group \`$RESOURCE_GROUP\`" \
            "az role assignment create --assignee <principal-id> --role AcrPull --scope $resource_id"
    else
        # Analyze RBAC assignments for security best practices
        echo "🔍 Analyzing RBAC assignment patterns..." >&2
        
        # Check for overly permissive assignments
        owner_assignments=$(echo "$rbac_assignments" | jq '.[] | select(.roleDefinitionName == "Owner") | .principalName' | wc -l)
        contributor_assignments=$(echo "$rbac_assignments" | jq '.[] | select(.roleDefinitionName == "Contributor") | .principalName' | wc -l)
        
        if [ "$owner_assignments" -gt 0 ]; then
            owner_principals=$(echo "$rbac_assignments" | jq -r '.[] | select(.roleDefinitionName == "Owner") | .principalName' | head -5 | tr '\n' ', ')
            add_issue \
                "Overly permissive Owner role assignments found" \
                3 \
                "Use least-privilege principle with specific ACR roles" \
                "$owner_assignments Owner role assignments found" \
                "Owner role grants full access to all Azure resources, not just ACR. Principals with Owner role: $owner_principals" \
                "Review Owner role assignments for ACR \`$ACR_NAME\` and replace with specific ACR roles (AcrPull, AcrPush, AcrDelete) where appropriate in resource group \`$RESOURCE_GROUP\`" \
                "az role assignment list --scope $resource_id --role Owner"
        fi
        
        if [ "$contributor_assignments" -gt 0 ]; then
            contributor_principals=$(echo "$rbac_assignments" | jq -r '.[] | select(.roleDefinitionName == "Contributor") | .principalName' | head -5 | tr '\n' ', ')
            add_issue \
                "Overly permissive Contributor role assignments found" \
                4 \
                "Use specific ACR roles instead of broad Contributor access" \
                "$contributor_assignments Contributor role assignments found" \
                "Contributor role grants broad access beyond ACR operations. Principals with Contributor role: $contributor_principals" \
                "Review Contributor role assignments for ACR \`$ACR_NAME\` and replace with specific ACR roles (AcrPull, AcrPush, AcrDelete) where appropriate in resource group \`$RESOURCE_GROUP\`" \
                "az role assignment list --scope $resource_id --role Contributor"
        fi
        
        # Check for appropriate ACR-specific roles
        acr_pull_count=$(echo "$rbac_assignments" | jq '.[] | select(.roleDefinitionName == "AcrPull") | .principalName' | wc -l)
        acr_push_count=$(echo "$rbac_assignments" | jq '.[] | select(.roleDefinitionName == "AcrPush") | .principalName' | wc -l)
        
        echo "📊 ACR-specific roles: AcrPull=$acr_pull_count, AcrPush=$acr_push_count" >&2
        
        # Check for service principals vs user accounts
        sp_count=$(echo "$rbac_assignments" | jq '.[] | select(.principalType == "ServicePrincipal") | .principalName' | wc -l)
        user_count=$(echo "$rbac_assignments" | jq '.[] | select(.principalType == "User") | .principalName' | wc -l)
        
        echo "📊 Principal types: Service Principals=$sp_count, Users=$user_count" >&2
        
        if [ "$user_count" -gt 5 ]; then
            add_issue \
                "High number of user account RBAC assignments" \
                4 \
                "Consider using service principals or managed identities for automated access" \
                "$user_count user accounts have RBAC assignments" \
                "Large number of individual user assignments can be difficult to manage and audit" \
                "Review user assignments for ACR \`$ACR_NAME\` and consider consolidating access through Azure AD groups or using service principals for automated systems in resource group \`$RESOURCE_GROUP\`" \
                "az role assignment list --scope $resource_id --assignee-object-type User"
        fi
    fi
else
    add_issue \
        "Failed to retrieve RBAC assignments" \
        3 \
        "Should be able to retrieve RBAC assignments for security analysis" \
        "az role assignment list command failed" \
        "Unable to analyze RBAC configuration for security assessment" \
        "Verify permissions to read RBAC assignments for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`, ensure you have Reader role or higher" \
        "az role assignment list --scope $resource_id"
fi

# 4. Check for private endpoints
echo "🔍 Checking private endpoint configuration..." >&2
private_endpoints=$(az network private-endpoint list --resource-group "$RESOURCE_GROUP" --query "[?privateLinkServiceConnections[0].privateLinkServiceId=='$resource_id']" -o json 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$private_endpoints" ]; then
    pe_count=$(echo "$private_endpoints" | jq '. | length // 0')
    if [ "$pe_count" -gt 0 ]; then
        echo "✅ Found $pe_count private endpoint(s)" >&2
        
        # Check if public access is still enabled when private endpoints exist
        if [ "$public_access" = "Enabled" ]; then
            add_issue \
                "Public access enabled despite private endpoints" \
                3 \
                "When private endpoints are configured, public access should typically be disabled" \
                "Both private endpoints ($pe_count) and public access are enabled" \
                "Having both private endpoints and public access may create unintended access paths" \
                "Consider disabling public network access for ACR \`$ACR_NAME\` if private endpoints provide sufficient connectivity for resource group \`$RESOURCE_GROUP\`" \
                "az acr update --name $ACR_NAME --public-network-enabled false"
        fi
    else
        echo "ℹ️ No private endpoints found" >&2
    fi
else
    echo "ℹ️ Unable to check private endpoints or none found" >&2
fi

# 5. Check repository permissions (if any repositories exist)
echo "🔍 Checking repository-level permissions..." >&2
repositories=$(az acr repository list --name "$ACR_NAME" -o json 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$repositories" ] && [ "$repositories" != "[]" ]; then
    repo_count=$(echo "$repositories" | jq '. | length')
    echo "📦 Found $repo_count repositories to analyze" >&2
    
    # Check for anonymous pull access (if supported by SKU)
    if [ "$sku" = "Premium" ]; then
        # Check if anonymous pull is enabled
        anonymous_pull=$(az acr config content-trust show --name "$ACR_NAME" --query "status" -o tsv 2>/dev/null)
        if [ "$anonymous_pull" = "enabled" ]; then
            echo "ℹ️ Content trust is enabled" >&2
        else
            echo "⚠️ Content trust is not enabled" >&2
            add_issue \
                "Content trust not enabled for Premium ACR" \
                4 \
                "Premium ACR should have content trust enabled for image integrity" \
                "Content trust is disabled" \
                "Content trust provides image integrity and authenticity verification using Docker Notary" \
                "Enable content trust for ACR \`$ACR_NAME\` to ensure image integrity and authenticity in resource group \`$RESOURCE_GROUP\`" \
                "az acr config content-trust update --name $ACR_NAME --status enabled"
        fi
    fi
else
    echo "📦 No repositories found or unable to list repositories" >&2
fi

# 6. Check for webhook security
echo "🔍 Checking webhook configuration..." >&2
webhooks=$(az acr webhook list --registry "$ACR_NAME" -o json 2>/dev/null)
if [ $? -eq 0 ] && [ -n "$webhooks" ] && [ "$webhooks" != "[]" ]; then
    webhook_count=$(echo "$webhooks" | jq '. | length')
    echo "🔗 Found $webhook_count webhook(s)" >&2
    
    # Check webhook security configurations
    insecure_webhooks=$(echo "$webhooks" | jq '.[] | select(.serviceUri | test("^http://")) | .name')
    if [ -n "$insecure_webhooks" ]; then
        webhook_names=$(echo "$insecure_webhooks" | tr '\n' ', ')
        add_issue \
            "Insecure HTTP webhooks detected" \
            2 \
            "Webhooks should use HTTPS for secure communication" \
            "Found webhooks using HTTP instead of HTTPS" \
            "HTTP webhooks transmit data in plaintext, potentially exposing sensitive information. Insecure webhooks: $webhook_names" \
            "Update webhook URLs for ACR \`$ACR_NAME\` to use HTTPS instead of HTTP for secure communication in resource group \`$RESOURCE_GROUP\`" \
            "az acr webhook update --name <webhook-name> --registry $ACR_NAME --uri <https-uri>"
    fi
    
    # Check for webhooks without custom headers (potential security enhancement)
    webhooks_without_auth=$(echo "$webhooks" | jq '.[] | select(.customHeaders == null or (.customHeaders | length) == 0) | .name')
    if [ -n "$webhooks_without_auth" ]; then
        webhook_names=$(echo "$webhooks_without_auth" | tr '\n' ', ')
        add_issue \
            "Webhooks without authentication headers" \
            4 \
            "Webhooks should include authentication headers for security" \
            "Found webhooks without custom authentication headers" \
            "Webhooks without authentication headers may be vulnerable to unauthorized triggering. Webhooks without auth: $webhook_names" \
            "Configure custom authentication headers for webhooks in ACR \`$ACR_NAME\` to ensure only authorized systems can receive webhook notifications for resource group \`$RESOURCE_GROUP\`" \
            "az acr webhook update --name <webhook-name> --registry $ACR_NAME --headers Authorization=Bearer-<token>"
    fi
else
    echo "🔗 No webhooks configured" >&2
fi

# 7. Generate security recommendations
echo "" >&2
echo "💡 Security recommendations:" >&2

if [ "$admin_enabled" = "true" ]; then
    echo "   1. Disable admin user and use RBAC or service principal authentication" >&2
fi

if [ "$public_access" = "Enabled" ]; then
    echo "   2. Consider using private endpoints and disabling public access" >&2
    if [ "$sku" = "Premium" ]; then
        echo "   3. Configure network access rules to restrict public access" >&2
    fi
fi

echo "   4. Regularly audit RBAC assignments and apply least-privilege principle" >&2
echo "   5. Use Azure AD groups for managing user access instead of individual assignments" >&2
echo "   6. Enable Azure Defender for container registries for security monitoring" >&2

if [ "$sku" = "Premium" ]; then
    echo "   7. Enable content trust for image integrity verification" >&2
fi

echo "   8. Monitor ACR access logs and set up alerts for suspicious activities" >&2

# Generate portal URLs
resource_id_encoded=$(echo "$resource_id" | sed 's|/|%2F|g')
portal_base="https://portal.azure.com/#@/resource$resource_id"

echo "" >&2
echo "🔗 Portal URLs:" >&2
echo "   ACR Overview: $portal_base" >&2
echo "   Access Control (IAM): ${portal_base}/users" >&2
echo "   Networking: ${portal_base}/networking" >&2
echo "   Webhooks: ${portal_base}/webhooks" >&2

# Clean up temporary files
rm -f acr_show_err.log

echo "" >&2
echo "✅ Security analysis complete" >&2

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE"

# Display summary
issue_count=$(jq '. | length' "$ISSUES_FILE")
echo "🔐 Security issues found: $issue_count" >&2

if [ "$issue_count" -gt 0 ]; then
    echo "" >&2
    echo "Security Issues:" >&2
    jq -r '.[] | "  - \(.title) (Severity: \(.severity))"' "$ISSUES_FILE" >&2
fi
