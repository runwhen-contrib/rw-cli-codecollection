#!/bin/bash

# Environment Variables:
# AWS_REGION
# EKS_CLUSTER_NAME - specific cluster to check (optional; if unset, checks all clusters in the region)
source "$(dirname "$0")/auth.sh"
auth

ISSUES_FILE="eks_fargate_health.json"
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
    echo "EKS Fargate Profile Health Report"
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
    echo "EKS Fargate Profile Health Report - Region: $AWS_REGION"
    echo "Clusters found: $cluster_count"
    echo "============================================"
fi

total_profiles=0
healthy_profiles=0
unhealthy_profiles=0

for cluster_name in $cluster_names; do
    echo ""
    echo "--------------------------------------------"
    echo "Cluster: $cluster_name"
    echo "--------------------------------------------"

    fargate_output=$(aws eks list-fargate-profiles --cluster-name "$cluster_name" --region "$AWS_REGION" --output json 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to list Fargate profiles for cluster $cluster_name"
        add_issue \
            "Failed to List Fargate Profiles for Cluster \`$cluster_name\`" \
            "aws eks list-fargate-profiles returned an error: $fargate_output" \
            "3" \
            "Check IAM permissions for eks:ListFargateProfiles.\nVerify cluster \`$cluster_name\` is accessible."
        continue
    fi

    profile_names=$(echo "$fargate_output" | jq -r '.fargateProfileNames[]?')
    profile_count=$(echo "$fargate_output" | jq '.fargateProfileNames | length')

    if [[ "$profile_count" -eq 0 ]]; then
        echo "  No Fargate profiles configured for this cluster."
        echo "  Info: This cluster uses only managed node groups or self-managed nodes."
        continue
    fi

    echo "  Fargate profiles: $profile_count"
    echo ""

    for profile in $profile_names; do
        total_profiles=$((total_profiles + 1))

        fp_info=$(aws eks describe-fargate-profile \
            --cluster-name "$cluster_name" \
            --fargate-profile-name "$profile" \
            --region "$AWS_REGION" \
            --output json 2>&1)

        if [[ $? -ne 0 ]]; then
            echo "  $profile: Failed to describe"
            unhealthy_profiles=$((unhealthy_profiles + 1))
            add_issue \
                "Failed to Describe Fargate Profile \`$profile\` on Cluster \`$cluster_name\`" \
                "aws eks describe-fargate-profile returned an error." \
                "3" \
                "Check IAM permissions for eks:DescribeFargateProfile.\nRun: aws eks describe-fargate-profile --cluster-name $cluster_name --fargate-profile-name $profile --region $AWS_REGION"
            continue
        fi

        fp_status=$(echo "$fp_info" | jq -r '.fargateProfile.status')
        fp_arn=$(echo "$fp_info" | jq -r '.fargateProfile.fargateProfileArn')
        fp_pod_execution_role=$(echo "$fp_info" | jq -r '.fargateProfile.podExecutionRoleArn')
        fp_subnets=$(echo "$fp_info" | jq -r '.fargateProfile.subnets // [] | join(", ")')
        fp_selectors=$(echo "$fp_info" | jq -c '.fargateProfile.selectors // []')
        fp_selector_count=$(echo "$fp_selectors" | jq 'length')
        fp_created_at=$(echo "$fp_info" | jq -r '.fargateProfile.createdAt')

        echo "  Profile: $profile"
        echo "    Status:             $fp_status"
        echo "    Pod Execution Role: $fp_pod_execution_role"
        echo "    Subnets:            $fp_subnets"
        echo "    Created:            $fp_created_at"
        echo "    Selectors ($fp_selector_count):"
        echo "$fp_selectors" | jq -r '.[] | "      Namespace: \(.namespace) | Labels: \(.labels // {} | to_entries | map("\(.key)=\(.value)") | join(", ") | if . == "" then "(none)" else . end)"'

        if [[ "$fp_status" == "ACTIVE" ]]; then
            echo "    Health: OK"
            healthy_profiles=$((healthy_profiles + 1))
        else
            echo "    Health: ERROR - Non-active status: $fp_status"
            unhealthy_profiles=$((unhealthy_profiles + 1))
            add_issue \
                "EKS Fargate Profile \`$profile\` on Cluster \`$cluster_name\` is $fp_status" \
                "Cluster: $cluster_name | Profile: $profile | Status: $fp_status | Expected: ACTIVE | Subnets: $fp_subnets | Selectors: $fp_selector_count" \
                "2" \
                "Check Fargate profile status: aws eks describe-fargate-profile --cluster-name $cluster_name --fargate-profile-name $profile --region $AWS_REGION\nIf the profile is stuck in CREATING or DELETING, check CloudTrail for errors.\nVerify the pod execution role \`$fp_pod_execution_role\` has the required permissions.\nVerify the subnets have available IP addresses."
        fi

        # Check for empty selectors
        if [[ "$fp_selector_count" -eq 0 ]]; then
            echo "    Warning: Profile has no selectors configured - no pods will be scheduled on Fargate"
            add_issue \
                "EKS Fargate Profile \`$profile\` Has No Selectors" \
                "Cluster: $cluster_name | Profile: $profile | The Fargate profile has no namespace selectors, so no pods will be scheduled on Fargate through this profile." \
                "4" \
                "Add selectors to the Fargate profile to match pods by namespace and optional labels.\nRun: aws eks describe-fargate-profile --cluster-name $cluster_name --fargate-profile-name $profile --region $AWS_REGION"
        fi

        echo ""
    done
done

# Final summary
issue_count=$(cat "$ISSUES_FILE" | jq '.issues | length')
echo "============================================"
echo "Fargate Profile Summary"
echo "  Total profiles:     $total_profiles"
echo "  Healthy (ACTIVE):   $healthy_profiles"
echo "  Unhealthy:          $unhealthy_profiles"
echo "  Issues detected:    $issue_count"
echo "============================================"
