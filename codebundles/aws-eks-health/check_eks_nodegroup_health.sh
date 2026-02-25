#!/bin/bash

# Environment Variables:
# AWS_REGION
# EKS_CLUSTER_NAME - specific cluster to check (optional; if unset, checks all clusters in the region)
source "$(dirname "$0")/auth.sh"
auth

ISSUES_FILE="eks_nodegroup_health.json"
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

# Determine which clusters to check
if [[ -n "${EKS_CLUSTER_NAME:-}" ]]; then
    cluster_names="$EKS_CLUSTER_NAME"
    cluster_count=1
    echo "============================================"
    echo "EKS Node Group Health Report"
    echo "Cluster: $EKS_CLUSTER_NAME"
    echo "Region:  $AWS_REGION"
    echo "============================================"
else
    eks_clusters=$(aws eks list-clusters --region "$AWS_REGION" --output json --query 'clusters[*]' 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to list EKS clusters in region $AWS_REGION"
        echo "$eks_clusters"
        add_issue \
            "Failed to List EKS Clusters in \`$AWS_REGION\`" \
            "aws eks list-clusters returned an error: $eks_clusters" \
            "2" \
            "Check AWS credentials and permissions.\nVerify the region \`$AWS_REGION\` is correct."
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
    echo "EKS Node Group Health Report - Region: $AWS_REGION"
    echo "Clusters found: $cluster_count"
    echo "============================================"
fi

total_nodegroups=0
healthy_nodegroups=0
unhealthy_nodegroups=0
total_desired_nodes=0

for cluster_name in $cluster_names; do
    echo ""
    echo "--------------------------------------------"
    echo "Cluster: $cluster_name"
    echo "--------------------------------------------"

    nodegroups_output=$(aws eks list-nodegroups --cluster-name "$cluster_name" --region "$AWS_REGION" --output json 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to list node groups for cluster $cluster_name"
        add_issue \
            "Failed to List Node Groups for Cluster \`$cluster_name\`" \
            "aws eks list-nodegroups returned an error: $nodegroups_output" \
            "3" \
            "Check IAM permissions for eks:ListNodegroups.\nVerify cluster \`$cluster_name\` is accessible."
        continue
    fi

    nodegroup_names=$(echo "$nodegroups_output" | jq -r '.nodegroups[]?')
    nodegroup_count=$(echo "$nodegroups_output" | jq '.nodegroups | length')

    if [[ "$nodegroup_count" -eq 0 ]]; then
        echo "  No managed node groups found for this cluster."
        echo "  Info: This cluster may use Fargate profiles or self-managed node groups only."
        continue
    fi

    echo "  Managed node groups: $nodegroup_count"
    echo ""

    for ng in $nodegroup_names; do
        total_nodegroups=$((total_nodegroups + 1))

        ng_info=$(aws eks describe-nodegroup \
            --cluster-name "$cluster_name" \
            --nodegroup-name "$ng" \
            --region "$AWS_REGION" \
            --output json 2>&1)

        if [[ $? -ne 0 ]]; then
            echo "  $ng: Failed to describe"
            unhealthy_nodegroups=$((unhealthy_nodegroups + 1))
            add_issue \
                "Failed to Describe Node Group \`$ng\` on Cluster \`$cluster_name\`" \
                "aws eks describe-nodegroup returned an error." \
                "3" \
                "Check IAM permissions for eks:DescribeNodegroup.\nRun: aws eks describe-nodegroup --cluster-name $cluster_name --nodegroup-name $ng --region $AWS_REGION"
            continue
        fi

        ng_status=$(echo "$ng_info" | jq -r '.nodegroup.status')
        ng_desired=$(echo "$ng_info" | jq -r '.nodegroup.scalingConfig.desiredSize')
        ng_min=$(echo "$ng_info" | jq -r '.nodegroup.scalingConfig.minSize')
        ng_max=$(echo "$ng_info" | jq -r '.nodegroup.scalingConfig.maxSize')
        ng_instance_types=$(echo "$ng_info" | jq -r '.nodegroup.instanceTypes // [] | join(", ")')
        ng_ami=$(echo "$ng_info" | jq -r '.nodegroup.amiType')
        ng_capacity=$(echo "$ng_info" | jq -r '.nodegroup.capacityType // "ON_DEMAND"')
        ng_disk_size=$(echo "$ng_info" | jq -r '.nodegroup.diskSize // "N/A"')
        ng_k8s_version=$(echo "$ng_info" | jq -r '.nodegroup.version // "N/A"')
        ng_release_version=$(echo "$ng_info" | jq -r '.nodegroup.releaseVersion // "N/A"')
        ng_created_at=$(echo "$ng_info" | jq -r '.nodegroup.createdAt')
        ng_subnets=$(echo "$ng_info" | jq -r '.nodegroup.subnets // [] | join(", ")')
        ng_health_issues=$(echo "$ng_info" | jq '.nodegroup.health.issues // []')
        ng_health_count=$(echo "$ng_health_issues" | jq 'length')
        ng_update_config=$(echo "$ng_info" | jq -r '.nodegroup.updateConfig // {}')
        ng_max_unavailable=$(echo "$ng_update_config" | jq -r '.maxUnavailable // .maxUnavailablePercentage // "N/A"')

        total_desired_nodes=$((total_desired_nodes + ng_desired))

        echo "  Node Group: $ng"
        echo "    Status:           $ng_status"
        echo "    Kubernetes:       $ng_k8s_version (Release: $ng_release_version)"
        echo "    Instance Types:   $ng_instance_types"
        echo "    Capacity Type:    $ng_capacity"
        echo "    AMI Type:         $ng_ami"
        echo "    Disk Size:        ${ng_disk_size}GB"
        echo "    Scaling:          min=$ng_min, desired=$ng_desired, max=$ng_max"
        echo "    Max Unavailable:  $ng_max_unavailable"
        echo "    Subnets:          $ng_subnets"
        echo "    Created:          $ng_created_at"

        # Check node group status
        if [[ "$ng_status" == "ACTIVE" ]]; then
            healthy_nodegroups=$((healthy_nodegroups + 1))
            echo "    Health: OK"
        else
            unhealthy_nodegroups=$((unhealthy_nodegroups + 1))
            echo "    Health: ERROR - Status is $ng_status"
            add_issue \
                "EKS Node Group \`$ng\` on Cluster \`$cluster_name\` is $ng_status" \
                "Cluster: $cluster_name | Node Group: $ng | Status: $ng_status | Expected: ACTIVE | Desired: $ng_desired | Instance Types: $ng_instance_types | Capacity: $ng_capacity" \
                "2" \
                "Check node group status: aws eks describe-nodegroup --cluster-name $cluster_name --nodegroup-name $ng --region $AWS_REGION\nReview EC2 Auto Scaling Group activity.\nCheck for capacity issues in availability zones: $ng_subnets\nIf DEGRADED, check node group health issues and EC2 instance status."
        fi

        # Check health issues
        if [[ "$ng_health_count" -gt 0 ]]; then
            echo "    Health Issues ($ng_health_count):"
            echo "$ng_health_issues" | jq -r '.[] | "      Code: \(.code) | Message: \(.message)"'
            ng_health_details=$(echo "$ng_health_issues" | jq -r '[.[] | "Code: \(.code), Message: \(.message)"] | join("; ")')
            add_issue \
                "EKS Node Group \`$ng\` on Cluster \`$cluster_name\` Has $ng_health_count Health Issue(s)" \
                "Cluster: $cluster_name | Node Group: $ng | Issues: $ng_health_details | Instance Types: $ng_instance_types | Desired: $ng_desired" \
                "2" \
                "Review node group health issues.\nCommon issues: AccessDenied (check IAM role), AsgInstanceLaunchFailures (check instance types/quotas), InsufficientFreeAddresses (check subnet CIDR).\nRun: aws eks describe-nodegroup --cluster-name $cluster_name --nodegroup-name $ng --region $AWS_REGION --query nodegroup.health"
        fi

        # Check if desired is at min (potential scaling concern)
        if [[ "$ng_desired" -eq "$ng_min" && "$ng_desired" -eq "$ng_max" ]]; then
            echo "    Info: Fixed-size node group (min=desired=max=$ng_desired)"
        elif [[ "$ng_desired" -eq "$ng_max" && "$ng_max" -gt "$ng_min" ]]; then
            echo "    Warning: Node group is scaled to maximum capacity"
            add_issue \
                "EKS Node Group \`$ng\` on Cluster \`$cluster_name\` is at Maximum Capacity" \
                "Cluster: $cluster_name | Node Group: $ng | Desired: $ng_desired = Max: $ng_max | The node group cannot scale further. Workloads may be pending if additional capacity is needed." \
                "3" \
                "Review if the maximum node count is sufficient for current workloads.\nConsider increasing the max size: aws eks update-nodegroup-config --cluster-name $cluster_name --nodegroup-name $ng --region $AWS_REGION --scaling-config maxSize=<new_max>\nCheck for pending pods: kubectl get pods --all-namespaces --field-selector status.phase=Pending"
        fi

        # Check if desired is 0 (no nodes running)
        if [[ "$ng_desired" -eq 0 ]]; then
            echo "    Warning: Node group has 0 desired nodes"
            add_issue \
                "EKS Node Group \`$ng\` on Cluster \`$cluster_name\` Has 0 Desired Nodes" \
                "Cluster: $cluster_name | Node Group: $ng | Desired Size: 0 | No nodes are running in this node group." \
                "3" \
                "Verify this is intentional. If not, scale up the node group.\nRun: aws eks update-nodegroup-config --cluster-name $cluster_name --nodegroup-name $ng --region $AWS_REGION --scaling-config desiredSize=1"
        fi

        echo ""
    done
done

# Final summary
issue_count=$(cat "$ISSUES_FILE" | jq '.issues | length')
echo "============================================"
echo "Node Group Summary"
echo "  Total node groups:    $total_nodegroups"
echo "  Healthy (ACTIVE):     $healthy_nodegroups"
echo "  Unhealthy:            $unhealthy_nodegroups"
echo "  Total desired nodes:  $total_desired_nodes"
echo "  Issues detected:      $issue_count"
echo "============================================"
