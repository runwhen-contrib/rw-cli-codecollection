#!/bin/bash

set -o pipefail

# Environment variables
SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID:-}
RESOURCE_GROUP=${AZ_RESOURCE_GROUP:-}
ACR_NAME=${ACR_NAME:-}
USAGE_THRESHOLD=${USAGE_THRESHOLD:-80}
CRITICAL_THRESHOLD=${CRITICAL_THRESHOLD:-95}

ISSUES_FILE="storage_utilization_issues.json"
echo '[]' > "$ISSUES_FILE"

add_issue() {
    local title="$1"
    local severity="$2"
    local expected="$3"
    local actual="$4"
    local details="$5"
    local next_steps="$6"
    local reproduce_hint="$7"
    local observed_at="${8:-$(date '+%Y-%m-%d %H:%M:%S')}"
    
    # Escape JSON characters properly
    details=$(echo "$details" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    next_steps=$(echo "$next_steps" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    reproduce_hint=$(echo "$reproduce_hint" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    
    local issue="{\"title\":\"$title\",\"severity\":$severity,\"expected\":\"$expected\",\"actual\":\"$actual\",\"details\":\"$details\",\"next_steps\":\"$next_steps\",\"reproduce_hint\":\"$reproduce_hint\",\"observed_at\":\"$observed_at\"}"
    jq ". += [${issue}]" "$ISSUES_FILE" > temp.json && mv temp.json "$ISSUES_FILE"
}

# Helper function to convert bytes to human readable format
bytes_to_human() {
    local bytes=$1
    if [ "$bytes" -eq 0 ]; then
        echo "0 B"
        return
    fi
    
    local units=("B" "KB" "MB" "GB" "TB")
    local unit=0
    local size=$bytes
    
    while [ "$size" -ge 1024 ] && [ "$unit" -lt 4 ]; do
        size=$((size / 1024))
        unit=$((unit + 1))
    done
    
    echo "$size ${units[$unit]}"
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

echo "💾 Analyzing ACR storage utilization for registry: $ACR_NAME" >&2
echo "⚠️ Warning threshold: ${USAGE_THRESHOLD}%" >&2
echo "🚨 Critical threshold: ${CRITICAL_THRESHOLD}%" >&2

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

# Get ACR basic information
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
    exit 0
fi

# Extract ACR details
sku=$(echo "$acr_info" | jq -r '.sku.name // "Unknown"')
login_server=$(echo "$acr_info" | jq -r '.loginServer // "Unknown"')
location=$(echo "$acr_info" | jq -r '.location // "Unknown"')

echo "🏢 Registry: $ACR_NAME ($login_server)" >&2
echo "📊 SKU: $sku" >&2
echo "🌍 Location: $location" >&2

# Get storage usage information
echo "📈 Retrieving storage usage..." >&2
usage_info=$(az acr show-usage --name "$ACR_NAME" --subscription "$SUBSCRIPTION_ID" -o json 2>usage_err.log)
if [ $? -ne 0 ] || [ -z "$usage_info" ]; then
    error_details=$(cat usage_err.log 2>/dev/null || echo "Unknown error")
    
    add_issue \
        "Failed to retrieve storage usage information" \
        3 \
        "Should be able to retrieve storage usage" \
        "az acr show-usage command failed" \
        "Error: $error_details" \
        "Check permissions and verify ACR \`$ACR_NAME\` accessibility in resource group \`$RESOURCE_GROUP\`" \
        "az acr show-usage --name $ACR_NAME --subscription $SUBSCRIPTION_ID"
    
    echo "❌ Failed to retrieve storage usage" >&2
    rm -f usage_err.log acr_show_err.log
    exit 0
fi

# Extract storage metrics
storage_used=$(echo "$usage_info" | jq -r '.value[] | select(.name=="Size") | .currentValue // 0')
storage_quota=$(echo "$usage_info" | jq -r '.value[] | select(.name=="Size") | .limit // 0')

# Validate that storage values are numeric
if ! [[ "$storage_used" =~ ^[0-9]+$ ]]; then
    storage_used=0
fi

if ! [[ "$storage_quota" =~ ^[0-9]+$ ]]; then
    storage_quota=0
fi

# Convert to human readable format
storage_used_human=$(bytes_to_human "$storage_used")
storage_quota_human=$(bytes_to_human "$storage_quota")

echo "💾 Storage used: $storage_used_human ($storage_used bytes)" >&2
echo "📦 Storage quota: $storage_quota_human ($storage_quota bytes)" >&2

# Calculate usage percentage
if [ "$storage_quota" -gt 0 ]; then
    storage_percent=$(echo "scale=2; ($storage_used * 100) / $storage_quota" | bc -l 2>/dev/null || echo "0")
    
    # Validate storage_percent is a valid number
    if ! [[ "$storage_percent" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        storage_percent="0"
    fi
    
    storage_available=$((storage_quota - storage_used))
    storage_available_human=$(bytes_to_human "$storage_available")
    
    echo "📊 Storage utilization: ${storage_percent}%" >&2
    echo "🆓 Available space: $storage_available_human" >&2
    
    # Check critical threshold first
    if (( $(echo "$storage_percent > $CRITICAL_THRESHOLD" | bc -l) )); then
        add_issue \
            "Critical storage utilization: ${storage_percent}%" \
            1 \
            "Storage utilization should be below ${CRITICAL_THRESHOLD}%" \
            "Current utilization is ${storage_percent}% (${storage_used_human} of ${storage_quota_human})" \
            "Used: $storage_used bytes, Quota: $storage_quota bytes, Available: $storage_available bytes, Utilization: ${storage_percent}%" \
            "IMMEDIATE ACTION REQUIRED: Clean up unused images in ACR \`$ACR_NAME\`, implement retention policies, or upgrade SKU. Registry in resource group \`$RESOURCE_GROUP\` may become read-only soon." \
            "az acr show-usage --name $ACR_NAME"
            
    elif (( $(echo "$storage_percent > $USAGE_THRESHOLD" | bc -l) )); then
        add_issue \
            "High storage utilization: ${storage_percent}%" \
            2 \
            "Storage utilization should be below ${USAGE_THRESHOLD}%" \
            "Current utilization is ${storage_percent}% (${storage_used_human} of ${storage_quota_human})" \
            "Used: $storage_used bytes, Quota: $storage_quota bytes, Available: $storage_available bytes, Utilization: ${storage_percent}%" \
            "Clean up unused images in ACR \`$ACR_NAME\` with 'az acr repository delete', implement retention policies with 'az acr config retention', or consider upgrading SKU for resource group \`$RESOURCE_GROUP\`" \
            "az acr show-usage --name $ACR_NAME"
    fi
    
    # Provide SKU-specific recommendations based on usage
    case "$sku" in
        "Basic")
            if (( $(echo "$storage_percent > 70" | bc -l) )); then
                add_issue \
                    "Basic SKU approaching storage limits" \
                    3 \
                    "Consider upgrading SKU before reaching limits" \
                    "Basic SKU has limited storage capacity, currently at ${storage_percent}%" \
                    "Current SKU: Basic, Usage: ${storage_percent}%, Available: $storage_available_human" \
                    "Consider upgrading ACR \`$ACR_NAME\` to Standard or Premium SKU for increased storage capacity in resource group \`$RESOURCE_GROUP\`" \
                    "az acr update --name $ACR_NAME --sku Standard"
            fi
            ;;
        "Standard"|"Premium")
            if (( $(echo "$storage_percent > 90" | bc -l) )); then
                echo "💡 Consider implementing automated cleanup policies" >&2
            fi
            ;;
    esac
    
else
    add_issue \
        "Storage quota information unavailable" \
        3 \
        "Storage quota should be available for analysis" \
        "Storage quota is 0 or not reported" \
        "Storage used: $storage_used bytes, Quota: $storage_quota bytes" \
        "Verify ACR \`$ACR_NAME\` configuration and permissions in resource group \`$RESOURCE_GROUP\`, or contact Azure support" \
        "az acr show-usage --name $ACR_NAME --subscription $SUBSCRIPTION_ID"
    
    echo "⚠️ Storage quota information not available" >&2
fi

# Get repository information for detailed analysis
echo "📦 Analyzing repositories..." >&2

# Function to attempt ACR authentication using multiple methods
authenticate_to_acr() {
    echo "🔐 Authenticating to ACR registry..." >&2
    
    # Method 1: Try standard ACR login
    if az acr login --name "$ACR_NAME" 2>acr_login_err.log; then
        echo "✅ ACR authentication successful (standard login)" >&2
        rm -f acr_login_err.log
        return 0
    fi
    
    # Method 2: Try ACR login with expose-token for service principal scenarios
    echo "🔑 Trying ACR login with token exposure..." >&2
    if az acr login --name "$ACR_NAME" --expose-token 2>acr_login_err2.log; then
        echo "✅ ACR authentication successful (token-based)" >&2
        rm -f acr_login_err.log acr_login_err2.log
        return 0
    fi
    
    # Method 3: Try to refresh Azure authentication first, then retry
    echo "🔄 Refreshing Azure authentication..." >&2
    if az account get-access-token --refresh >/dev/null 2>&1; then
        echo "✅ Azure token refreshed, retrying ACR login..." >&2
        if az acr login --name "$ACR_NAME" 2>acr_login_err3.log; then
            echo "✅ ACR authentication successful (after token refresh)" >&2
            rm -f acr_login_err.log acr_login_err2.log acr_login_err3.log
            return 0
        fi
    fi
    
    # If all methods fail, log the errors but continue
    echo "⚠️ All ACR authentication methods failed, proceeding with repository listing..." >&2
    acr_login_error=$(cat acr_login_err.log acr_login_err2.log acr_login_err3.log 2>/dev/null | head -10)
    echo "Authentication errors: $acr_login_error" >&2
    rm -f acr_login_err.log acr_login_err2.log acr_login_err3.log
    return 1
}

# Attempt ACR authentication
authenticate_to_acr

# Now attempt to list repositories with better error handling
repo_list=$(az acr repository list --name "$ACR_NAME" -o json 2>repo_err.log)
repo_exit_code=$?

# If repository listing fails, try alternative method using REST API
if [ $repo_exit_code -ne 0 ]; then
    echo "🔄 Repository listing failed, trying alternative method..." >&2
    
    # Try using Azure REST API to get repository information
    access_token=$(az account get-access-token --resource https://management.azure.com/ --query accessToken -o tsv 2>/dev/null)
    if [ -n "$access_token" ] && [ "$access_token" != "null" ]; then
        echo "🌐 Attempting to get repository info via Azure REST API..." >&2
        
        # Try to get repository information through Azure Resource Manager
        registry_url="https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
        
        # This won't give us repositories directly, but we can check if the registry is accessible
        registry_info=$(curl -s -H "Authorization: Bearer $access_token" "$registry_url?api-version=2021-09-01" 2>/dev/null)
        if echo "$registry_info" | jq -e '.properties' >/dev/null 2>&1; then
            echo "✅ Registry accessible via REST API, but repository listing requires ACR data plane access" >&2
        fi
    fi
fi

if [ $repo_exit_code -eq 0 ] && [ -n "$repo_list" ] && [ "$repo_list" != "[]" ]; then
    repo_count=$(echo "$repo_list" | jq '. | length')
    echo "📚 Total repositories: $repo_count" >&2
    
    if [ "$repo_count" -gt 0 ]; then
        echo "🔍 Top repositories by tag count:" >&2
        
        # Analyze top repositories (limit to first 5 for performance)
        echo "$repo_list" | jq -r '.[:5][]' | while read -r repo; do
            if [ -n "$repo" ]; then
                tag_count=$(az acr repository show-tags --name "$ACR_NAME" --repository "$repo" --output json 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
                echo "   $repo: $tag_count tags" >&2
            fi
        done
        
        # Check for repositories with many tags (potential cleanup candidates)
        large_repos=$(mktemp)
        echo "$repo_list" | jq -r '.[]' | head -10 | while read -r repo; do
            if [ -n "$repo" ]; then
                tag_count=$(az acr repository show-tags --name "$ACR_NAME" --repository "$repo" --output json 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
                if [ "$tag_count" -gt 50 ]; then
                    echo "$repo:$tag_count" >> "$large_repos"
                fi
            fi
        done
        
        if [ -s "$large_repos" ]; then
            large_repo_list=$(cat "$large_repos" | head -5)
            add_issue \
                "Repositories with excessive tags detected" \
                4 \
                "Repositories should have reasonable number of tags" \
                "Found repositories with >50 tags each" \
                "Large repositories: $(echo "$large_repo_list" | tr '\n' ', ')" \
                "Review and clean up old tags in ACR \`$ACR_NAME\`, implement retention policies to automatically manage tag lifecycle for resource group \`$RESOURCE_GROUP\`" \
                "az acr config retention update --registry $ACR_NAME --status enabled --days 30 --policy-type UntaggedManifests"
        fi
        
        rm -f "$large_repos"
    fi
else
    # Check if it's a permission/authentication error or truly no repositories
    if [ $repo_exit_code -ne 0 ]; then
        repo_error=$(cat repo_err.log 2>/dev/null || echo "Unknown error")
        echo "📦 Unable to list repositories - Error: $repo_error" >&2
        
        # Check if it's a permission/authentication error
        if echo "$repo_error" | grep -i -E "(permission|unauthorized|forbidden|access|CONNECTIVITY_REFRESH_TOKEN_ERROR|denied)" > /dev/null; then
            # Check if it's specifically a token refresh error
            if echo "$repo_error" | grep -i "CONNECTIVITY_REFRESH_TOKEN_ERROR" > /dev/null; then
                add_issue \
                    "Azure authentication token refresh error" \
                    3 \
                    "Azure authentication should work without token refresh errors" \
                    "ACR access failed due to token connectivity issues" \
                    "Error: $repo_error" \
                    "Try refreshing Azure authentication with 'az login' or 'az account get-access-token --refresh'. If using service principal, verify credentials and network connectivity. For ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`, ensure proper RBAC roles (AcrPull/AcrPush) are assigned." \
                    "az login --scope https://management.azure.com//.default && az acr login --name $ACR_NAME"
            else
                add_issue \
                    "Insufficient permissions to list repositories" \
                    3 \
                    "Should have permission to list repositories" \
                    "az acr repository list command failed with permission error" \
                    "Error: $repo_error" \
                    "Grant 'AcrPull' or 'AcrPush' role to the current user/service principal for ACR \`$ACR_NAME\` in resource group \`$RESOURCE_GROUP\`. Check Azure RBAC assignments. If admin user is disabled, ensure proper Azure AD authentication." \
                    "az role assignment create --assignee \$(az account show --query user.name -o tsv) --role AcrPull --scope /subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
            fi
        else
            add_issue \
                "Failed to retrieve repository list" \
                3 \
                "Should be able to list repositories" \
                "az acr repository list command failed" \
                "Error: $repo_error" \
                "Check ACR \`$ACR_NAME\` accessibility, network connectivity, and Azure CLI authentication for resource group \`$RESOURCE_GROUP\`" \
                "az acr repository list --name $ACR_NAME"
        fi
    else
        echo "📦 No repositories found" >&2
        if [ "$storage_used" -gt 0 ]; then
            add_issue \
                "Storage used but no repositories visible" \
                3 \
                "If storage is used, repositories should be visible" \
                "Storage shows ${storage_used_human} used but no repositories found" \
                "Storage used: $storage_used bytes, Repositories found: 0" \
                "Check repository permissions for ACR \`$ACR_NAME\`, verify ACR configuration in resource group \`$RESOURCE_GROUP\`, or investigate orphaned data. May indicate deleted repositories with remaining manifest data." \
                "az acr repository list --name $ACR_NAME"
        fi
    fi
fi

# Clean up repository and authentication error logs
rm -f repo_err.log acr_login_err.log

# Check for retention policies
echo "🔄 Checking retention policies..." >&2
retention_policy=$(az acr config retention show --registry "$ACR_NAME" -o json 2>/dev/null)
if [ -n "$retention_policy" ]; then
    retention_enabled=$(echo "$retention_policy" | jq -r '.status // "disabled"')
    if [ "$retention_enabled" = "enabled" ]; then
        retention_days=$(echo "$retention_policy" | jq -r '.days // 0')
        echo "✅ Retention policy enabled: $retention_days days" >&2
    else
        echo "⚠️ Retention policy disabled" >&2
        add_issue \
            "Retention policy not enabled" \
            4 \
            "Retention policy should be enabled to manage storage automatically" \
            "Retention policy is currently disabled" \
            "Without retention policies, old images accumulate and consume storage" \
            "Enable retention policy for ACR \`$ACR_NAME\` to automatically clean up untagged manifests and old images in resource group \`$RESOURCE_GROUP\`" \
            "az acr config retention update --registry $ACR_NAME --status enabled --days 30 --policy-type UntaggedManifests"
    fi
else
    echo "ℹ️ Retention policy information not available (may not be supported in current SKU)" >&2
fi

# Generate recommendations based on current state
echo "" >&2
echo "💡 Storage optimization recommendations:" >&2

if [ "$storage_quota" -gt 0 ] && [ -n "$storage_percent" ]; then
    storage_percent_int=$(echo "$storage_percent" | cut -d'.' -f1)
    
    # Ensure storage_percent_int is a valid integer
    if [[ "$storage_percent_int" =~ ^[0-9]+$ ]]; then
        if [ "$storage_percent_int" -gt 50 ]; then
            echo "   1. Review and delete unused repositories: az acr repository delete --name $ACR_NAME --repository <repo-name>" >&2
            echo "   2. Clean up old tags: az acr repository untag --name $ACR_NAME --image <image:tag>" >&2
            echo "   3. Enable retention policies: az acr config retention update --registry $ACR_NAME --status enabled" >&2
        fi
        
        if [ "$storage_percent_int" -gt 80 ]; then
            echo "   4. Consider upgrading SKU for more storage: az acr update --name $ACR_NAME --sku Premium" >&2
            echo "   5. Implement automated cleanup in CI/CD pipelines" >&2
        fi
    fi
fi

echo "   6. Monitor storage usage regularly with: az acr show-usage --name $ACR_NAME" >&2
echo "   7. Use multi-stage builds to reduce image sizes" >&2
echo "   8. Implement image scanning to identify and remove vulnerable images" >&2

# Generate portal URLs
resource_id="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
portal_url="https://portal.azure.com/#@/resource$resource_id"

echo "" >&2
echo "🔗 Portal URLs:" >&2
echo "   ACR Overview: $portal_url" >&2
echo "   Usage: ${portal_url}/usage" >&2
echo "   Repositories: ${portal_url}/repositories" >&2
echo "   Retention Policies: ${portal_url}/retentionPolicies" >&2

# Clean up temporary files
rm -f acr_show_err.log usage_err.log

echo "" >&2
echo "✅ Storage utilization analysis complete" >&2

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
