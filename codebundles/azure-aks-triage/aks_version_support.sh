#!/bin/bash

# Checks AKS cluster Kubernetes version support status and estimates cost impact
# of running unsupported or soon-to-expire versions.
#
# Environment Variables:
# AKS_CLUSTER              - cluster name
# AZ_RESOURCE_GROUP        - resource group
# AZURE_RESOURCE_SUBSCRIPTION_ID - subscription (optional, falls back to current)

if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }
fi

ISSUES_FILE="aks_version_support.json"
issues_json='{"issues": []}'

add_issue() {
    local title="$1" details="$2" severity="$3" next_steps="$4"
    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg details "$details" \
        --arg severity "$severity" \
        --arg next_steps "$next_steps" \
        '.issues += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_step": $next_steps}]'
    )
}

# AKS pricing constants (USD)
AKS_FREE_HOURLY="0.00"
AKS_STANDARD_HOURLY="0.10"
AKS_PREMIUM_HOURLY="0.60"
HOURS_PER_MONTH=730

standard_monthly=$(echo "scale=2; $AKS_STANDARD_HOURLY * $HOURS_PER_MONTH" | bc -l)
premium_monthly=$(echo "scale=2; $AKS_PREMIUM_HOURLY * $HOURS_PER_MONTH" | bc -l)
premium_annual=$(echo "scale=2; $premium_monthly * 12" | bc -l)
premium_uplift_monthly=$(echo "scale=2; ($AKS_PREMIUM_HOURLY - $AKS_STANDARD_HOURLY) * $HOURS_PER_MONTH" | bc -l)

echo "============================================"
echo "AKS Kubernetes Version Support Check"
echo "Cluster:        $AKS_CLUSTER"
echo "Resource Group: $AZ_RESOURCE_GROUP"
echo "Subscription:   $subscription"
echo "============================================"
echo ""

# Get cluster details
CLUSTER_DETAILS=$(az aks show --name "$AKS_CLUSTER" --resource-group "$AZ_RESOURCE_GROUP" -o json 2>&1)
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to describe AKS cluster $AKS_CLUSTER"
    echo "$CLUSTER_DETAILS"
    add_issue \
        "Failed to Describe AKS Cluster \`$AKS_CLUSTER\` for Version Check" \
        "az aks show returned an error: $CLUSTER_DETAILS" \
        "2" \
        "Check Azure credentials and permissions.\nVerify cluster \`$AKS_CLUSTER\` exists in resource group \`$AZ_RESOURCE_GROUP\`."
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

k8s_version=$(echo "$CLUSTER_DETAILS" | jq -r '.kubernetesVersion')
cluster_location=$(echo "$CLUSTER_DETAILS" | jq -r '.location')
provisioning_state=$(echo "$CLUSTER_DETAILS" | jq -r '.provisioningState')
sku_tier=$(echo "$CLUSTER_DETAILS" | jq -r '.sku.tier // "Free"')
auto_upgrade_channel=$(echo "$CLUSTER_DETAILS" | jq -r '.autoUpgradeProfile.upgradeChannel // "none"')

# Extract minor version (e.g., "1.28" from "1.28.5")
cluster_minor="${k8s_version%.*}"

echo "Kubernetes Version: $k8s_version (minor: $cluster_minor)"
echo "Location:           $cluster_location"
echo "SKU Tier:           $sku_tier"
echo "Auto-Upgrade:       $auto_upgrade_channel"
echo ""

# Get supported versions for this location
echo "Fetching supported Kubernetes versions for location $cluster_location..."
supported_versions_json=$(az aks get-versions --location "$cluster_location" -o json 2>&1)
if [[ $? -ne 0 ]]; then
    echo "Warning: Could not fetch supported versions for location $cluster_location"
    echo "$supported_versions_json"
    echo "Proceeding with version display only."
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

# Extract supported minor versions
supported_minors=$(echo "$supported_versions_json" | jq -r '.values[]?.version // empty' | sort -t. -k1,1n -k2,2n | uniq)
# Also try the orchestrators format (older API versions)
if [[ -z "$supported_minors" ]]; then
    supported_minors=$(echo "$supported_versions_json" | jq -r '.orchestrators[]?.orchestratorVersion // empty' | sed 's/\.[^.]*$//' | sort -t. -k1,1n -k2,2n | uniq)
fi

latest_version=$(echo "$supported_minors" | tail -1)
default_version=$(echo "$supported_versions_json" | jq -r '.values[]? | select(.isDefault == true) | .version // empty' | head -1)
[[ -z "$default_version" ]] && default_version="$latest_version"

echo "Supported minor versions: $(echo $supported_minors | tr '\n' ' ')"
echo "Latest version:           $latest_version"
echo "Default version:          $default_version"
echo ""

if [[ -z "$latest_version" ]]; then
    echo "Warning: Could not determine latest supported version."
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

# Check if cluster minor version is in supported set
version_supported=false
for v in $supported_minors; do
    if [[ "$v" == "$cluster_minor" ]]; then
        version_supported=true
        break
    fi
done

latest_minor_num=$(echo "$latest_version" | cut -d. -f2)
cluster_minor_num=$(echo "$cluster_minor" | cut -d. -f2)
versions_behind=$((latest_minor_num - cluster_minor_num))

# Check node pool versions for skew
echo "-------Node Pool Version Details--------"
node_pools=$(echo "$CLUSTER_DETAILS" | jq -c '.agentPoolProfiles[]')
pool_version_issues=""
while IFS= read -r pool; do
    pool_name=$(echo "$pool" | jq -r '.name')
    pool_version=$(echo "$pool" | jq -r '.currentOrchestratorVersion // .orchestratorVersion // "unknown"')
    pool_count=$(echo "$pool" | jq -r '.count')
    pool_vm_size=$(echo "$pool" | jq -r '.vmSize')
    echo "  $pool_name: K8s $pool_version | Nodes: $pool_count | VM: $pool_vm_size"

    pool_minor="${pool_version%.*}"
    if [[ "$pool_minor" != "$cluster_minor" ]]; then
        pool_version_issues+="Node pool '$pool_name' is on $pool_version (control plane: $k8s_version). "
    fi
done <<< "$node_pools"
echo ""

if [[ "$version_supported" == "false" ]]; then
    echo "⚠️  CRITICAL: Version $cluster_minor is NOT in the AKS supported versions list for $cluster_location"
    echo ""
    echo "SUPPORT STATUS: UNSUPPORTED / END OF LIFE"
    echo "  - No security patches or bug fixes"
    echo "  - No SLA coverage regardless of SKU tier"
    echo "  - Upgrades from unsupported versions skip minor versions with NO guarantee of functionality"
    echo ""
    echo "COST & RISK IMPACT:"
    echo "  - Clusters on unsupported versions are excluded from SLA and support agreements"
    echo "  - If Long-Term Support (LTS) was desired, Premium tier is required (\$$premium_monthly/month)"
    echo "  - LTS Premium uplift vs Standard: +\$$premium_uplift_monthly/month (\$$premium_annual/year)"
    echo "  - Microsoft may force auto-upgrade if auto-upgrade channel is enabled"
    echo ""

    add_issue \
        "AKS Cluster \`$AKS_CLUSTER\` Running Unsupported Kubernetes $k8s_version — No SLA or Security Patches" \
        "Cluster: $AKS_CLUSTER | Resource Group: $AZ_RESOURCE_GROUP | Version: $k8s_version | Location: $cluster_location | SKU: $sku_tier | Latest Supported: $latest_version | Versions Behind: $versions_behind | Auto-Upgrade: $auto_upgrade_channel\n\nVERSION STATUS: UNSUPPORTED / END OF LIFE\nKubernetes $k8s_version ($cluster_minor) is no longer in the AKS supported versions list for $cluster_location.\n\nIMPACT:\n- No SLA coverage (regardless of Free/Standard/Premium tier)\n- No security patches or bug fixes from Microsoft\n- Upgrading from unsupported versions is not guaranteed to work and is excluded from SLA\n- Microsoft recommends recreating the cluster if significantly out of date\n\nCOST CONTEXT:\n- AKS Standard tier: \$$standard_monthly/month, Premium (with LTS): \$$premium_monthly/month\n- Premium tier provides Long-Term Support for up to 2 years on selected versions\n- Without Premium LTS, AKS supports each version for ~12 months\n- Running unsupported means paying for infrastructure without platform-level guarantees\n$([[ -n "$pool_version_issues" ]] && echo "\nNODE POOL SKEW: $pool_version_issues")" \
        "1" \
        "Immediately plan upgrade of AKS cluster \`$AKS_CLUSTER\` to a supported Kubernetes version (latest: $latest_version).\nReview AKS upgrade guide: https://learn.microsoft.com/en-us/azure/aks/upgrade-aks-cluster\nIf version is significantly behind, consider recreating the cluster on a supported version.\nTest workload compatibility with the target version in a staging environment.\nConsider enabling auto-upgrade channel to prevent future version drift.\nEvaluate Premium tier with LTS if extended version support is needed."

elif [[ $versions_behind -ge 2 ]]; then
    echo "⚠️  WARNING: Version $cluster_minor is $versions_behind minor versions behind latest ($latest_version)"
    echo "   Approaching end of support — upgrade recommended."
    echo ""
    echo "COST CONTEXT:"
    echo "  - If LTS is needed: Premium tier at \$$premium_monthly/month (vs Standard \$$standard_monthly/month)"
    echo "  - Premium LTS uplift: +\$$premium_uplift_monthly/month per cluster"
    echo "  - Without LTS, this version will become unsupported within months"
    echo ""

    add_issue \
        "AKS Cluster \`$AKS_CLUSTER\` Approaching End of Support on Kubernetes $k8s_version" \
        "Cluster: $AKS_CLUSTER | Resource Group: $AZ_RESOURCE_GROUP | Version: $k8s_version | Location: $cluster_location | SKU: $sku_tier | Latest: $latest_version | Versions Behind: $versions_behind | Auto-Upgrade: $auto_upgrade_channel\n\nVERSION STATUS: NEARING END OF SUPPORT\nKubernetes $cluster_minor is $versions_behind minor versions behind the latest ($latest_version). AKS supports each version for approximately 12 months after GA.\n\nCOST IMPACT IF NOT UPGRADED:\n- Once unsupported: no SLA, no security patches, no support coverage\n- To extend support: Premium tier required at \$$premium_monthly/month (vs Standard \$$standard_monthly/month)\n- Premium LTS uplift: +\$$premium_uplift_monthly/month per cluster\n- Premium LTS annual cost: \$$premium_annual/year per cluster\n\nRECOMMENDATION:\nUpgrade proactively to avoid running on an unsupported version or paying for Premium LTS.\n$([[ -n "$pool_version_issues" ]] && echo "\nNODE POOL SKEW: $pool_version_issues")" \
        "3" \
        "Schedule upgrade of AKS cluster \`$AKS_CLUSTER\` to a more recent Kubernetes version (latest: $latest_version).\nReview AKS supported versions: https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions\nTest workload compatibility in a staging environment.\nConfigure auto-upgrade channel to \`stable\` or \`patch\` to prevent future drift.\nEvaluate whether Premium tier LTS is needed for your organization's upgrade cadence."

elif [[ $versions_behind -ge 1 ]]; then
    echo "ℹ️  Version $cluster_minor is $versions_behind minor version(s) behind latest ($latest_version)"
    echo "   Still in standard support, but plan your next upgrade."
    echo ""

    add_issue \
        "AKS Cluster \`$AKS_CLUSTER\` Running Kubernetes $k8s_version — $versions_behind Version(s) Behind Latest" \
        "Cluster: $AKS_CLUSTER | Version: $k8s_version | Latest: $latest_version | Versions Behind: $versions_behind | SKU: $sku_tier | Auto-Upgrade: $auto_upgrade_channel\n\nVERSION STATUS: SUPPORTED (STANDARD)\nThis version is still in standard support but is $versions_behind minor version(s) behind the latest. Plan an upgrade to stay current.\n$([[ -n "$pool_version_issues" ]] && echo "\nNODE POOL SKEW: $pool_version_issues")" \
        "4" \
        "Plan upgrade of AKS cluster \`$AKS_CLUSTER\` to latest Kubernetes version ($latest_version) during next maintenance window.\nReview release notes for breaking changes.\nConsider enabling auto-upgrade channel if not already configured."
else
    echo "✅  Version $cluster_minor is current (latest: $latest_version)"
    echo ""
fi

# Warn about node pool version skew
if [[ -n "$pool_version_issues" ]]; then
    echo "⚠️  Node pool version skew detected: $pool_version_issues"
    echo ""
fi

echo "-------AKS Pricing Reference--------"
echo "Free tier:     \$0/month (no SLA)"
echo "Standard tier: \$$standard_monthly/month (\$0.10/hr) with SLA"
echo "Premium tier:  \$$premium_monthly/month (\$0.60/hr) with SLA + LTS"
echo "LTS provides extended Kubernetes version support for up to 2 years."
echo "============================================"

echo "$issues_json" > "$ISSUES_FILE"
