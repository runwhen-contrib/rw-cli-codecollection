#!/bin/bash

# Checks EKS cluster Kubernetes version support status and estimates cost impact
# of running deprecated or extended-support versions.
#
# Environment Variables:
# AWS_REGION
# EKS_CLUSTER_NAME - specific cluster to check (optional; if unset, checks all clusters in the region)
source "$(dirname "$0")/auth.sh"
auth

ISSUES_FILE="eks_version_support.json"
echo '{"issues": []}' > "$ISSUES_FILE"

add_issue() {
    local title="$1"
    local details="$2"
    local severity="$3"
    local next_steps="$4"
    issues_json=$(cat "$ISSUES_FILE")
    issues_json=$(echo "$issues_json" | jq \
        --arg title "$title" \
        --arg details "$details" \
        --arg severity "$severity" \
        --arg next_steps "$next_steps" \
        '.issues += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_step": $next_steps}]'
    )
    echo "$issues_json" > "$ISSUES_FILE"
}

# EKS pricing constants (USD)
EKS_STANDARD_HOURLY="0.10"
EKS_EXTENDED_SURCHARGE_HOURLY="0.60"
EKS_EXTENDED_TOTAL_HOURLY="0.70"
HOURS_PER_MONTH=730

standard_monthly=$(echo "scale=2; $EKS_STANDARD_HOURLY * $HOURS_PER_MONTH" | bc -l)
surcharge_monthly=$(echo "scale=2; $EKS_EXTENDED_SURCHARGE_HOURLY * $HOURS_PER_MONTH" | bc -l)
extended_monthly=$(echo "scale=2; $EKS_EXTENDED_TOTAL_HOURLY * $HOURS_PER_MONTH" | bc -l)
surcharge_annual=$(echo "scale=2; $surcharge_monthly * 12" | bc -l)

echo "============================================"
echo "EKS Kubernetes Version Support Check"
echo "Region: $AWS_REGION"
echo "============================================"
echo ""

# Build the set of currently-supported K8s minor versions by querying the
# addon compatibility matrix. vpc-cni is present on every cluster so it gives
# the full picture of versions EKS still supports (standard + extended).
echo "Fetching supported Kubernetes versions from EKS addon compatibility matrix..."
supported_raw=$(aws eks describe-addon-versions --region "$AWS_REGION" \
    --addon-name vpc-cni \
    --query 'addons[].addonVersions[].compatibilities[].clusterVersion' \
    --output text 2>/dev/null)

if [[ -z "$supported_raw" ]]; then
    supported_raw=$(aws eks describe-addon-versions --region "$AWS_REGION" \
        --query 'addons[0].addonVersions[].compatibilities[].clusterVersion' \
        --output text 2>/dev/null)
fi

SUPPORTED_VERSIONS=$(echo "$supported_raw" | tr '\t' '\n' | grep -E '^[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n | uniq)
LATEST_VERSION=$(echo "$SUPPORTED_VERSIONS" | tail -1)

if [[ -z "$LATEST_VERSION" ]]; then
    echo "Warning: Could not determine supported Kubernetes versions from EKS API."
    echo "Proceeding with version display only."
fi

echo "Supported versions: $(echo $SUPPORTED_VERSIONS | tr '\n' ' ')"
echo "Latest version:     $LATEST_VERSION"
echo ""

# Determine which clusters to check
if [[ -n "${EKS_CLUSTER_NAME:-}" ]]; then
    cluster_names="$EKS_CLUSTER_NAME"
else
    cluster_list=$(aws eks list-clusters --region "$AWS_REGION" --output json --query 'clusters[*]' 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to list EKS clusters in region $AWS_REGION"
        echo "$cluster_list"
        add_issue \
            "Failed to List EKS Clusters in \`$AWS_REGION\` for Version Check" \
            "aws eks list-clusters returned an error: $cluster_list" \
            "2" \
            "Check AWS credentials and permissions.\nVerify the region \`$AWS_REGION\` is correct.\nEnsure the IAM role has eks:ListClusters permission."
        cat "$ISSUES_FILE"
        exit 0
    fi
    cluster_names=$(echo "$cluster_list" | jq -r '.[]')
    if [[ -z "$cluster_names" ]]; then
        echo "No EKS clusters found in region $AWS_REGION."
        cat "$ISSUES_FILE"
        exit 0
    fi
fi

version_minor() {
    echo "$1" | cut -d. -f2
}

for cluster_name in $cluster_names; do
    echo "--------------------------------------------"
    echo "Cluster: $cluster_name"
    echo "--------------------------------------------"

    cluster_info=$(aws eks describe-cluster --name "$cluster_name" --region "$AWS_REGION" --output json 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "  Error: Failed to describe cluster $cluster_name"
        add_issue \
            "Failed to Describe EKS Cluster \`$cluster_name\` for Version Check" \
            "aws eks describe-cluster returned an error: $cluster_info" \
            "2" \
            "Check IAM permissions for eks:DescribeCluster.\nVerify cluster \`$cluster_name\` exists in region \`$AWS_REGION\`."
        continue
    fi

    k8s_version=$(echo "$cluster_info" | jq -r '.cluster.version')
    platform_version=$(echo "$cluster_info" | jq -r '.cluster.platformVersion')
    cluster_status=$(echo "$cluster_info" | jq -r '.cluster.status')
    created_at=$(echo "$cluster_info" | jq -r '.cluster.createdAt')

    echo "  Kubernetes Version: $k8s_version"
    echo "  Platform Version:   $platform_version"
    echo "  Status:             $cluster_status"
    echo "  Created:            $created_at"

    if [[ -z "$LATEST_VERSION" ]]; then
        echo "  Skipping support check — could not determine supported versions"
        echo ""
        continue
    fi

    # Check if cluster version is in the supported set
    version_in_supported=false
    for v in $SUPPORTED_VERSIONS; do
        if [[ "$v" == "$k8s_version" ]]; then
            version_in_supported=true
            break
        fi
    done

    latest_minor=$(version_minor "$LATEST_VERSION")
    cluster_minor=$(version_minor "$k8s_version")
    versions_behind=$((latest_minor - cluster_minor))

    if [[ "$version_in_supported" == "false" ]]; then
        echo "  ⚠️  CRITICAL: Version $k8s_version is NOT in the EKS supported versions list"
        echo "     This cluster is past end-of-life and subject to forced auto-upgrade."
        echo ""
        echo "  COST IMPACT:"
        echo "     Extended support surcharge (while active): +\$$surcharge_monthly/month per cluster"
        echo "     Standard EKS: \$$standard_monthly/month → Extended: \$$extended_monthly/month (7x)"
        echo ""

        add_issue \
            "EKS Cluster \`$cluster_name\` Running End-of-Life Kubernetes $k8s_version (+\$$surcharge_monthly/mo surcharge risk)" \
            "Cluster: $cluster_name | Region: $AWS_REGION | Version: $k8s_version | Platform: $platform_version | Latest Available: $LATEST_VERSION | Versions Behind: $versions_behind\n\nVERSION STATUS: END OF LIFE / UNSUPPORTED\nKubernetes $k8s_version is no longer in standard or extended support for EKS.\n\nCOST IMPACT:\n- While in extended support, AWS charged an additional \$0.60/hr per cluster\n- Extended support surcharge: \$$surcharge_monthly/month (\$$surcharge_annual/year) per cluster\n- Standard EKS control plane: \$$standard_monthly/month vs Extended: \$$extended_monthly/month\n- This is a 7x cost multiplier on the control plane\n\nRISK:\n- No security patches or bug fixes from AWS\n- AWS will force auto-upgrade to the earliest supported version\n- No SLA guarantees\n- Potential compatibility issues with EKS managed add-ons" \
            "1" \
            "Immediately plan upgrade of EKS cluster \`$cluster_name\` to a supported Kubernetes version (latest: $LATEST_VERSION).\nReview the EKS upgrade documentation: https://docs.aws.amazon.com/eks/latest/userguide/update-cluster.html\nTest workload compatibility with the target version in a staging environment.\nUpdate node groups and managed add-ons after control plane upgrade.\nReview Kubernetes release notes for breaking changes across each skipped minor version."

    elif [[ $versions_behind -ge 3 ]]; then
        echo "  ⚠️  WARNING: Version $k8s_version is $versions_behind minor versions behind latest ($LATEST_VERSION)"
        echo "     This version is likely in EKS Extended Support."
        echo ""
        echo "  COST IMPACT:"
        echo "     Extended support surcharge: +\$$surcharge_monthly/month per cluster"
        echo "     Standard: \$$standard_monthly/month → Extended: \$$extended_monthly/month (7x)"
        echo ""

        add_issue \
            "EKS Cluster \`$cluster_name\` Likely in Extended Support on Kubernetes $k8s_version (+\$$surcharge_monthly/mo surcharge)" \
            "Cluster: $cluster_name | Region: $AWS_REGION | Version: $k8s_version | Platform: $platform_version | Latest Available: $LATEST_VERSION | Versions Behind: $versions_behind\n\nVERSION STATUS: LIKELY IN EXTENDED SUPPORT\nKubernetes $k8s_version is $versions_behind minor versions behind the latest ($LATEST_VERSION). EKS provides 14 months of standard support followed by 12 months of extended support per version.\n\nCOST IMPACT:\n- Extended support surcharge: +\$0.60/hr per cluster = +\$$surcharge_monthly/month\n- Standard EKS control plane: \$$standard_monthly/month\n- Extended support total: \$$extended_monthly/month (7x standard)\n- Annual surcharge: \$$surcharge_annual per cluster\n\nEKS EXTENDED SUPPORT:\n- AWS charges \$0.60/hr/cluster on top of the \$0.10/hr standard fee\n- After extended support ends (12 months), AWS forces auto-upgrade\n- Upgrade now to eliminate the surcharge" \
            "2" \
            "Plan upgrade of EKS cluster \`$cluster_name\` from $k8s_version to a recent version (latest: $LATEST_VERSION) to eliminate the \$$surcharge_monthly/month extended support surcharge.\nReview the EKS version calendar: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html\nTest workload compatibility with the target version.\nSchedule a maintenance window for the upgrade.\nUpdate node groups and managed add-ons after control plane upgrade."

    elif [[ $versions_behind -ge 2 ]]; then
        echo "  ℹ️  Version $k8s_version is $versions_behind minor versions behind latest ($LATEST_VERSION)"
        echo "     Approaching end of standard support — plan upgrade to avoid surcharges."
        echo ""

        add_issue \
            "EKS Cluster \`$cluster_name\` Approaching End of Standard Support on Kubernetes $k8s_version" \
            "Cluster: $cluster_name | Region: $AWS_REGION | Version: $k8s_version | Latest Available: $LATEST_VERSION | Versions Behind: $versions_behind\n\nVERSION STATUS: NEARING END OF STANDARD SUPPORT\nKubernetes $k8s_version is $versions_behind minor versions behind the latest. This version will enter extended support soon.\n\nUPCOMING COST IMPACT (if not upgraded):\n- Extended support surcharge: +\$0.60/hr per cluster = +\$$surcharge_monthly/month\n- Standard: \$$standard_monthly/month → Extended: \$$extended_monthly/month (7x)\n- Annual additional cost: \$$surcharge_annual per cluster\n\nUpgrade before this version enters extended support to avoid the surcharge." \
            "3" \
            "Schedule upgrade of EKS cluster \`$cluster_name\` to a more recent Kubernetes version before extended support charges begin.\nReview the EKS version support calendar for exact end-of-standard-support dates.\nTest workload compatibility in a staging environment.\nCoordinate with application teams for upgrade scheduling."
    else
        echo "  ✅  Version $k8s_version is current ($versions_behind version(s) behind latest $LATEST_VERSION)"
        echo ""
    fi
done

echo ""
issue_count=$(cat "$ISSUES_FILE" | jq '.issues | length')
echo "============================================"
echo "Version support check complete. Issues found: $issue_count"
echo "============================================"
echo ""
echo "EKS Extended Support Pricing Reference:"
echo "  Standard control plane: \$0.10/hr (\$$standard_monthly/month)"
echo "  Extended support:       \$0.70/hr (\$$extended_monthly/month) — 7x standard"
echo "  Surcharge per cluster:  \$0.60/hr (\$$surcharge_monthly/month, \$$surcharge_annual/year)"
echo "============================================"
