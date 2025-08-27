#!/bin/bash

set -o pipefail

# Environment variables
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}
USAGE_THRESHOLD=${USAGE_THRESHOLD:-80}

ISSUES_FILE="usage_sku_issues.json"
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

echo "🔍 Checking ACR SKU and usage for registry: $ACR_NAME" >&2

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

# Get ACR information including SKU
echo "📋 Retrieving ACR information..." >&2
acr_info=$(az acr show --name "$ACR_NAME" --resource-group "$RESOURCE_GROUP" -o json 2>acr_show_err.log)
if [ $? -ne 0 ] || [ -z "$acr_info" ]; then
    error_details=$(cat acr_show_err.log 2>/dev/null || echo "Unknown error")
    
    if echo "$error_details" | grep -q "AuthorizationFailed"; then
        add_issue \
            "Insufficient permissions to access ACR '$ACR_NAME'" \
            3 \
            "User/service principal should have 'Reader' or higher role on the registry" \
            "az acr show failed due to insufficient permissions" \
            "Error: $error_details" \
            "Assign 'Reader' or higher role to the user/service principal for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`" \
            "az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP"
    else
        add_issue \
            "ACR '$ACR_NAME' not found or unreachable" \
            3 \
            "ACR should exist and be accessible" \
            "az acr show command failed" \
            "Error: $error_details" \
            "Verify ACR name \`$ACR_NAME\`, resource group \`$RESOURCE_GROUP\`, and network connectivity" \
            "az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP"
    fi
    
    echo "❌ Failed to retrieve ACR information" >&2
    rm -f acr_show_err.log
    cat "$ISSUES_FILE"
    exit 0
fi

# Extract SKU information
sku=$(echo "$acr_info" | jq -r '.sku.name // "Unknown"')
tier=$(echo "$acr_info" | jq -r '.sku.tier // "Unknown"')
admin_enabled=$(echo "$acr_info" | jq -r '.adminUserEnabled // false')
login_server=$(echo "$acr_info" | jq -r '.loginServer // "Unknown"')
creation_date=$(echo "$acr_info" | jq -r '.creationDate // "Unknown"')
location=$(echo "$acr_info" | jq -r '.location // "Unknown"')

echo "📊 ACR SKU: $sku ($tier)" >&2
echo "🏢 Login Server: $login_server" >&2
echo "📅 Created: $creation_date" >&2
echo "🌍 Location: $location" >&2
echo "👤 Admin User Enabled: $admin_enabled" >&2

# Get usage information
echo "📈 Retrieving usage information..." >&2
usage_info=$(az acr show-usage --name "$ACR_NAME" --subscription "$SUBSCRIPTION_ID" -o json 2>usage_err.log)
if [ $? -ne 0 ] || [ -z "$usage_info" ]; then
    error_details=$(cat usage_err.log 2>/dev/null || echo "Unknown error")
    
    add_issue \
        "Failed to retrieve ACR usage information" \
        3 \
        "Should be able to retrieve usage information" \
        "az acr show-usage command failed" \
        "Error: $error_details" \
        "Check permissions and verify ACR \`$ACR_NAME\` exists in resource group \`$RESOURCE_GROUP\`" \
        "az acr show-usage --name $ACR_NAME --subscription $SUBSCRIPTION_ID"
    
    echo "⚠️ Failed to retrieve usage information"
    rm -f usage_err.log acr_show_err.log
    exit 0
fi

# Process usage information using jq directly
storage_used=$(echo "$usage_info" | jq -r '.value[] | select(.name == "Size") | .currentValue // 0')
storage_quota=$(echo "$usage_info" | jq -r '.value[] | select(.name == "Size") | .limitValue // 0')
webhook_used=$(echo "$usage_info" | jq -r '.value[] | select(.name == "Webhooks") | .currentValue // 0')
webhook_quota=$(echo "$usage_info" | jq -r '.value[] | select(.name == "Webhooks") | .limitValue // 0')

# Set defaults if values are empty or null
storage_used=${storage_used:-0}
storage_quota=${storage_quota:-0}
webhook_used=${webhook_used:-0}
webhook_quota=${webhook_quota:-0}

echo "💾 Storage Used: $storage_used bytes" >&2
echo "📦 Storage Quota: $storage_quota bytes" >&2
echo "🔗 Webhooks Used: $webhook_used" >&2
echo "🔗 Webhook Quota: $webhook_quota" >&2

# Calculate storage usage percentage
if [ "$storage_quota" -gt 0 ]; then
    storage_percent=$(echo "scale=2; ($storage_used * 100) / $storage_quota" | bc -l 2>/dev/null || echo "0")
    echo "📊 Storage Usage: ${storage_percent}%" >&2
    
    # Check if storage usage exceeds threshold
    if (( $(echo "$storage_percent > $USAGE_THRESHOLD" | bc -l) )); then
        storage_gb=$(echo "scale=2; $storage_used / 1073741824" | bc -l 2>/dev/null || echo "0")
        quota_gb=$(echo "scale=2; $storage_quota / 1073741824" | bc -l 2>/dev/null || echo "0")
        
        add_issue \
            "High ACR storage usage: ${storage_percent}%" \
            3 \
            "Storage usage should be below ${USAGE_THRESHOLD}%" \
            "Current usage is ${storage_percent}% (${storage_gb}GB of ${quota_gb}GB)" \
            "Storage Used: $storage_used bytes, Quota: $storage_quota bytes, Threshold: ${USAGE_THRESHOLD}%" \
            "Consider cleaning up unused images in ACR \`$ACR_NAME\`, implementing retention policies, or upgrading to a higher SKU tier in resource group \`$RESOURCE_GROUP\`" \
            "az acr show-usage --name $ACR_NAME"
    fi
else
    echo "⚠️ Storage quota information not available" >&2
fi

# Check webhook usage
if [ "$webhook_quota" -gt 0 ]; then
    webhook_percent=$(echo "scale=2; ($webhook_used * 100) / $webhook_quota" | bc -l 2>/dev/null || echo "0")
    echo "🔗 Webhook Usage: ${webhook_percent}%" >&2
    
    if (( $(echo "$webhook_percent > 90" | bc -l) )); then
        add_issue \
            "High webhook usage: ${webhook_percent}%" \
            4 \
            "Webhook usage should be below 90%" \
            "Current webhook usage is ${webhook_percent}% ($webhook_used of $webhook_quota)" \
            "Webhooks Used: $webhook_used, Quota: $webhook_quota" \
            "Review webhook configurations for ACR \`$ACR_NAME\` and consider upgrading SKU if more webhooks are needed in resource group \`$RESOURCE_GROUP\`" \
            "az acr webhook list --registry $ACR_NAME"
    fi
fi

# SKU-specific recommendations
case "$sku" in
    "Basic")
        echo "ℹ️ Basic SKU detected - limited features available" >&2
        add_issue \
            "ACR is using Basic SKU with limited features" \
            4 \
            "Consider upgrading to Standard or Premium for production workloads" \
            "Current SKU: Basic" \
            "Basic SKU limitations: No geo-replication, no webhook support, limited storage" \
            "Consider upgrading ACR \`$ACR_NAME\` to Standard SKU for webhooks and better performance, or Premium for geo-replication and advanced features in resource group \`$RESOURCE_GROUP\`" \
            "az acr update --name $ACR_NAME --sku Standard"
        ;;
    "Standard")
        echo "✅ Standard SKU detected - good for most workloads"
        ;;
    "Premium")
        echo "🚀 Premium SKU detected - full feature set available"
        ;;
    *)
        add_issue \
            "Unknown or unsupported ACR SKU: $sku" \
            3 \
            "ACR should have a valid SKU (Basic, Standard, or Premium)" \
            "Current SKU: $sku" \
            "Unknown SKU detected: $sku" \
            "Verify ACR \`$ACR_NAME\` configuration in resource group \`$RESOURCE_GROUP\` and contact support if needed" \
            "az acr show --name $ACR_NAME --query sku"
        ;;
esac

# Check admin user configuration
if [ "$admin_enabled" = "true" ]; then
    add_issue \
        "ACR admin user is enabled" \
        4 \
        "Admin user should be disabled for production environments" \
        "Admin user is currently enabled" \
        "Admin user provides full access with username/password authentication, which poses security risks in production environments" \
        "Disable admin user for ACR \`$ACR_NAME\` and use Azure AD authentication with service principals or managed identities in resource group \`$RESOURCE_GROUP\`" \
        "az acr update --name $ACR_NAME --admin-enabled false"
fi

# Generate portal URLs for easy access
resource_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
portal_url="https://portal.azure.com/#@/resource$resource_id"

# Output portal URLs to stderr so they don't interfere with JSON parsing
echo "" >&2
echo "🔗 Portal URLs:" >&2
echo "   ACR Overview: $portal_url" >&2
echo "   Usage: ${portal_url}/usage" >&2
echo "   Access Keys: ${portal_url}/accessKey" >&2

# Output the JSON file content to stdout for Robot Framework
cat "$ISSUES_FILE"

# Clean up temporary files
rm -f acr_show_err.log usage_err.log

echo "" >&2
echo "✅ ACR SKU and usage analysis complete" >&2

# Display summary
issue_count=$(jq '. | length' "$ISSUES_FILE")
echo "📋 Issues found: $issue_count" >&2

if [ "$issue_count" -gt 0 ]; then
    echo "" >&2
    echo "Issues:" >&2
    jq -r '.[] | "  - \(.title) (Severity: \(.severity))"' "$ISSUES_FILE" >&2
fi
