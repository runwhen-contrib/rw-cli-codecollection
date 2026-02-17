#!/bin/bash

# Environment Variables:
# AWS_REGION
source "$(dirname "$0")/auth.sh"
auth

ISSUES_FILE="eks_cluster_health.json"
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

# Get list of EKS clusters
eks_clusters=$(aws eks list-clusters --region "$AWS_REGION" --output json --query 'clusters[*]' 2>&1)
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to list EKS clusters in region $AWS_REGION"
    echo "$eks_clusters"
    add_issue \
        "Failed to List EKS Clusters in \`$AWS_REGION\`" \
        "aws eks list-clusters returned an error: $eks_clusters" \
        "2" \
        "Check AWS credentials and permissions.\nVerify the region \`$AWS_REGION\` is correct.\nEnsure the IAM role has eks:ListClusters permission."
    cat "$ISSUES_FILE"
    exit 0
fi

cluster_names=$(echo "$eks_clusters" | jq -r '.[]')
cluster_count=$(echo "$eks_clusters" | jq '. | length')

if [[ "$cluster_count" -eq 0 ]]; then
    echo "No EKS clusters found in region $AWS_REGION."
    exit 0
fi

echo "============================================"
echo "EKS Cluster Health Report - Region: $AWS_REGION"
echo "Clusters found: $cluster_count"
echo "============================================"

for cluster_name in $cluster_names; do
    echo ""
    echo "============================================"
    echo "Cluster: $cluster_name"
    echo "============================================"

    cluster_info=$(aws eks describe-cluster --name "$cluster_name" --region "$AWS_REGION" --output json 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to describe cluster $cluster_name"
        add_issue \
            "Failed to Describe EKS Cluster \`$cluster_name\`" \
            "aws eks describe-cluster returned an error: $cluster_info" \
            "2" \
            "Check IAM permissions for eks:DescribeCluster.\nVerify cluster \`$cluster_name\` exists in region \`$AWS_REGION\`."
        continue
    fi

    # Extract cluster details
    status=$(echo "$cluster_info" | jq -r '.cluster.status')
    k8s_version=$(echo "$cluster_info" | jq -r '.cluster.version')
    platform_version=$(echo "$cluster_info" | jq -r '.cluster.platformVersion')
    endpoint=$(echo "$cluster_info" | jq -r '.cluster.endpoint')
    endpoint_public=$(echo "$cluster_info" | jq -r '.cluster.resourcesVpcConfig.endpointPublicAccess')
    endpoint_private=$(echo "$cluster_info" | jq -r '.cluster.resourcesVpcConfig.endpointPrivateAccess')
    vpc_id=$(echo "$cluster_info" | jq -r '.cluster.resourcesVpcConfig.vpcId')
    cluster_arn=$(echo "$cluster_info" | jq -r '.cluster.arn')
    created_at=$(echo "$cluster_info" | jq -r '.cluster.createdAt')
    health_issues=$(echo "$cluster_info" | jq '.cluster.health.issues // []')
    health_issues_count=$(echo "$health_issues" | jq 'length')

    # Configuration summary
    echo ""
    echo "-------Configuration Summary--------"
    echo "Status:             $status"
    echo "Kubernetes Version: $k8s_version"
    echo "Platform Version:   $platform_version"
    echo "ARN:                $cluster_arn"
    echo "VPC:                $vpc_id"
    echo "Endpoint (Public):  $endpoint_public"
    echo "Endpoint (Private): $endpoint_private"
    echo "Created:            $created_at"

    # Check cluster status
    if [[ "$status" != "ACTIVE" ]]; then
        echo "Error: Cluster $cluster_name has non-ACTIVE status: $status"
        add_issue \
            "EKS Cluster \`$cluster_name\` is Not Active (Status: $status)" \
            "Cluster: $cluster_name | Region: $AWS_REGION | Status: $status | Expected: ACTIVE | Impact: Cluster may not be operational" \
            "2" \
            "Check cluster status: aws eks describe-cluster --name $cluster_name --region $AWS_REGION\nReview recent EKS operations and CloudTrail events.\nIf cluster is UPDATING, wait for the update to complete.\nIf cluster is FAILED, review CloudWatch logs and consider recreating."
    else
        echo "OK: Cluster status is ACTIVE"
    fi

    # Check health issues
    if [[ "$health_issues_count" -gt 0 ]]; then
        echo ""
        echo "-------Health Issues ($health_issues_count found)--------"
        echo "$health_issues" | jq -r '.[] | "  Code: \(.code) | Message: \(.message)"'
        health_details=$(echo "$health_issues" | jq -r '[.[] | "Code: \(.code), Message: \(.message)"] | join("; ")')
        add_issue \
            "EKS Cluster \`$cluster_name\` Has $health_issues_count Health Issue(s)" \
            "Cluster: $cluster_name | Region: $AWS_REGION | Health Issues: $health_details" \
            "2" \
            "Review the health issues reported by EKS.\nCheck AWS Health Dashboard for regional issues.\nReview CloudWatch logs for the cluster.\nRun: aws eks describe-cluster --name $cluster_name --region $AWS_REGION --query cluster.health"
    else
        echo "OK: No health issues reported"
    fi

    # Check logging configuration
    logging_types=$(echo "$cluster_info" | jq -r '[.cluster.logging.clusterLogging[]? | select(.enabled == true) | .types[]?] | join(", ")')
    if [[ -z "$logging_types" || "$logging_types" == "null" ]]; then
        echo "Warning: No cluster logging types are enabled"
        add_issue \
            "EKS Cluster \`$cluster_name\` Has No Logging Enabled" \
            "Cluster: $cluster_name | Region: $AWS_REGION | No logging types are enabled. Consider enabling api, audit, authenticator, controllerManager, or scheduler logging." \
            "4" \
            "Enable cluster logging: aws eks update-cluster-config --name $cluster_name --region $AWS_REGION --logging '{\"clusterLogging\":[{\"types\":[\"api\",\"audit\",\"authenticator\",\"controllerManager\",\"scheduler\"],\"enabled\":true}]}'"
    else
        echo "Logging enabled:    $logging_types"
    fi

    # Check encryption configuration
    encryption_config=$(echo "$cluster_info" | jq -r '.cluster.encryptionConfig // []')
    encryption_count=$(echo "$encryption_config" | jq 'length')
    if [[ "$encryption_count" -eq 0 ]]; then
        echo "Info: Secrets encryption is not configured (using default etcd encryption)"
    else
        echo "OK: Secrets encryption is configured"
    fi

    # Check add-ons
    echo ""
    echo "-------Add-ons--------"
    addons_output=$(aws eks list-addons --cluster-name "$cluster_name" --region "$AWS_REGION" --output json 2>&1)
    if [[ $? -eq 0 ]]; then
        addon_names=$(echo "$addons_output" | jq -r '.addons[]?')
        if [[ -z "$addon_names" ]]; then
            echo "No managed add-ons found"
        else
            for addon in $addon_names; do
                addon_info=$(aws eks describe-addon --cluster-name "$cluster_name" --addon-name "$addon" --region "$AWS_REGION" --output json 2>&1)
                if [[ $? -eq 0 ]]; then
                    addon_status=$(echo "$addon_info" | jq -r '.addon.status')
                    addon_version=$(echo "$addon_info" | jq -r '.addon.addonVersion')
                    addon_health=$(echo "$addon_info" | jq -r '.addon.health.issues // [] | length')
                    echo "  $addon: $addon_status (version: $addon_version)"
                    if [[ "$addon_status" != "ACTIVE" ]]; then
                        addon_issues=$(echo "$addon_info" | jq -r '.addon.health.issues // [] | [.[] | "Code: \(.code), Message: \(.message)"] | join("; ")')
                        add_issue \
                            "EKS Add-on \`$addon\` on Cluster \`$cluster_name\` is $addon_status" \
                            "Cluster: $cluster_name | Add-on: $addon | Status: $addon_status | Version: $addon_version | Health Issues: $addon_issues" \
                            "3" \
                            "Check add-on health: aws eks describe-addon --cluster-name $cluster_name --addon-name $addon --region $AWS_REGION\nTry updating the add-on: aws eks update-addon --cluster-name $cluster_name --addon-name $addon --region $AWS_REGION\nReview the EKS add-on compatibility matrix for Kubernetes version $k8s_version."
                    fi
                    if [[ "$addon_health" -gt 0 ]]; then
                        echo "    WARNING: $addon_health health issue(s) detected"
                    fi
                else
                    echo "  $addon: Failed to describe"
                fi
            done
        fi
    else
        echo "Failed to list add-ons"
    fi

    # Check managed node groups
    echo ""
    echo "-------Managed Node Groups--------"
    nodegroups_output=$(aws eks list-nodegroups --cluster-name "$cluster_name" --region "$AWS_REGION" --output json 2>&1)
    if [[ $? -eq 0 ]]; then
        nodegroup_names=$(echo "$nodegroups_output" | jq -r '.nodegroups[]?')
        if [[ -z "$nodegroup_names" ]]; then
            echo "No managed node groups found"
        else
            total_nodes=0
            for ng in $nodegroup_names; do
                ng_info=$(aws eks describe-nodegroup --cluster-name "$cluster_name" --nodegroup-name "$ng" --region "$AWS_REGION" --output json 2>&1)
                if [[ $? -eq 0 ]]; then
                    ng_status=$(echo "$ng_info" | jq -r '.nodegroup.status')
                    ng_desired=$(echo "$ng_info" | jq -r '.nodegroup.scalingConfig.desiredSize')
                    ng_min=$(echo "$ng_info" | jq -r '.nodegroup.scalingConfig.minSize')
                    ng_max=$(echo "$ng_info" | jq -r '.nodegroup.scalingConfig.maxSize')
                    ng_instance_types=$(echo "$ng_info" | jq -r '.nodegroup.instanceTypes // [] | join(", ")')
                    ng_ami=$(echo "$ng_info" | jq -r '.nodegroup.amiType')
                    ng_health_issues=$(echo "$ng_info" | jq '.nodegroup.health.issues // []')
                    ng_health_count=$(echo "$ng_health_issues" | jq 'length')

                    echo "  $ng: $ng_status"
                    echo "    Scaling: min=$ng_min, desired=$ng_desired, max=$ng_max"
                    echo "    Instance Types: $ng_instance_types"
                    echo "    AMI Type: $ng_ami"

                    total_nodes=$((total_nodes + ng_desired))

                    if [[ "$ng_status" != "ACTIVE" ]]; then
                        add_issue \
                            "EKS Node Group \`$ng\` on Cluster \`$cluster_name\` is $ng_status" \
                            "Cluster: $cluster_name | Node Group: $ng | Status: $ng_status | Desired: $ng_desired | Instance Types: $ng_instance_types" \
                            "2" \
                            "Check node group status: aws eks describe-nodegroup --cluster-name $cluster_name --nodegroup-name $ng --region $AWS_REGION\nReview Auto Scaling Group activity in the EC2 console.\nCheck for capacity issues in the target availability zones."
                    fi

                    if [[ "$ng_health_count" -gt 0 ]]; then
                        echo "    WARNING: $ng_health_count health issue(s):"
                        echo "$ng_health_issues" | jq -r '.[] | "      Code: \(.code) | Message: \(.message)"'
                        ng_health_details=$(echo "$ng_health_issues" | jq -r '[.[] | "Code: \(.code), Message: \(.message)"] | join("; ")')
                        add_issue \
                            "EKS Node Group \`$ng\` on Cluster \`$cluster_name\` Has Health Issues" \
                            "Cluster: $cluster_name | Node Group: $ng | Health Issues: $ng_health_details" \
                            "2" \
                            "Review node group health issues.\nCheck EC2 instance status in the node group.\nReview Auto Scaling Group events.\nRun: aws eks describe-nodegroup --cluster-name $cluster_name --nodegroup-name $ng --region $AWS_REGION --query nodegroup.health"
                    else
                        echo "    Health: OK"
                    fi
                fi
            done
            echo ""
            echo "Total desired nodes across all node groups: $total_nodes"
        fi
    fi

    # Check Fargate profiles summary
    echo ""
    echo "-------Fargate Profiles--------"
    fargate_output=$(aws eks list-fargate-profiles --cluster-name "$cluster_name" --region "$AWS_REGION" --output json 2>&1)
    if [[ $? -eq 0 ]]; then
        fargate_names=$(echo "$fargate_output" | jq -r '.fargateProfileNames[]?')
        if [[ -z "$fargate_names" ]]; then
            echo "No Fargate profiles configured"
        else
            for fp in $fargate_names; do
                fp_info=$(aws eks describe-fargate-profile --cluster-name "$cluster_name" --fargate-profile-name "$fp" --region "$AWS_REGION" --output json 2>&1)
                if [[ $? -eq 0 ]]; then
                    fp_status=$(echo "$fp_info" | jq -r '.fargateProfile.status')
                    fp_selectors=$(echo "$fp_info" | jq -r '.fargateProfile.selectors // [] | [.[] | .namespace] | join(", ")')
                    echo "  $fp: $fp_status (namespaces: $fp_selectors)"
                fi
            done
        fi
    fi

    echo ""
    echo "============================================"
done

# Final summary
issue_count=$(cat "$ISSUES_FILE" | jq '.issues | length')
echo ""
echo "============================================"
echo "Health check complete. Found $issue_count issue(s)."
echo "============================================"
