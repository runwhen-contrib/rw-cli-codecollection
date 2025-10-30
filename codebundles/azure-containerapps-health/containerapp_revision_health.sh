#!/bin/bash

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

echo "Checking revision health for Container App: $CONTAINER_APP_NAME"

# Get all revisions for the Container App
revisions_data=$(az containerapp revision list --name "$CONTAINER_APP_NAME" --resource-group "$AZ_RESOURCE_GROUP" --output json)

if [[ -z "$revisions_data" || "$revisions_data" == "null" ]]; then
    echo "Error: No revisions found for Container App $CONTAINER_APP_NAME in resource group $AZ_RESOURCE_GROUP."
    exit 1
fi

issues_json='{"issues": []}'

# Count revisions
total_revisions=$(echo "$revisions_data" | jq 'length')
active_revisions=$(echo "$revisions_data" | jq '[.[] | select(.properties.active == true)] | length')
inactive_revisions=$(echo "$revisions_data" | jq '[.[] | select(.properties.active == false)] | length')

echo "Total revisions: $total_revisions"
echo "Active revisions: $active_revisions"
echo "Inactive revisions: $inactive_revisions"

# Check if there are no active revisions
if [[ $active_revisions -eq 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "No Active Revisions" \
        --arg nextStep "Investigate why no revisions are active for Container App $CONTAINER_APP_NAME. Check deployment status." \
        --arg severity "1" \
        --arg details "No active revisions found out of $total_revisions total revisions" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Analyze each revision
failed_revisions=0
provisioning_failed_revisions=0
unhealthy_revisions=0

echo "Analyzing individual revisions..."

while IFS= read -r revision; do
    revision_name=$(echo "$revision" | jq -r '.name')
    active=$(echo "$revision" | jq -r '.properties.active')
    provisioning_state=$(echo "$revision" | jq -r '.properties.provisioningState // "Unknown"')
    health_state=$(echo "$revision" | jq -r '.properties.healthState // "Unknown"')
    traffic_weight=$(echo "$revision" | jq -r '.properties.trafficWeight // 0')
    replicas=$(echo "$revision" | jq -r '.properties.replicas // 0')
    created_time=$(echo "$revision" | jq -r '.properties.createdTime // "Unknown"')
    
    echo "Revision: $revision_name"
    echo "  Active: $active"
    echo "  Provisioning State: $provisioning_state" 
    echo "  Health State: $health_state"
    echo "  Traffic Weight: $traffic_weight%"
    echo "  Replicas: $replicas"
    echo "  Created: $created_time"
    
    # Check provisioning state
    if [[ "$provisioning_state" == "Failed" ]]; then
        provisioning_failed_revisions=$((provisioning_failed_revisions + 1))
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Revision Provisioning Failed" \
            --arg nextStep "Investigate provisioning failure for revision $revision_name. Check deployment logs and configuration." \
            --arg severity "2" \
            --arg details "Revision $revision_name failed to provision with state: $provisioning_state" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    elif [[ "$provisioning_state" != "Succeeded" && "$active" == "true" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Active Revision Not Fully Provisioned" \
            --arg nextStep "Monitor provisioning progress for active revision $revision_name." \
            --arg severity "3" \
            --arg details "Active revision $revision_name has provisioning state: $provisioning_state" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    # Check health state
    if [[ "$health_state" == "Unhealthy" ]]; then
        unhealthy_revisions=$((unhealthy_revisions + 1))
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Unhealthy Revision" \
            --arg nextStep "Investigate health issues for revision $revision_name. Check application logs and health probes." \
            --arg severity "2" \
            --arg details "Revision $revision_name is unhealthy" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    # Check if active revision has no traffic
    if [[ "$active" == "true" && "$traffic_weight" == "0" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Active Revision With No Traffic" \
            --arg nextStep "Review traffic routing configuration for revision $revision_name. Active revision should receive traffic." \
            --arg severity "3" \
            --arg details "Active revision $revision_name has 0% traffic weight" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    # Check if active revision has no replicas
    if [[ "$active" == "true" && "$replicas" == "0" ]]; then
        issues_json=$(echo "$issues_json" | jq \
            --arg title "Active Revision With No Replicas" \
            --arg nextStep "Investigate why active revision $revision_name has no running replicas. Check scaling configuration." \
            --arg severity "2" \
            --arg details "Active revision $revision_name has 0 replicas" \
            '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
        )
    fi
    
    echo ""
done < <(echo "$revisions_data" | jq -c '.[]')

# Check for too many revisions (Container Apps keeps only latest revisions by default)
if [[ $total_revisions -gt 10 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "High Number of Revisions" \
        --arg nextStep "Consider cleaning up old revisions for Container App $CONTAINER_APP_NAME to improve management." \
        --arg severity "4" \
        --arg details "Total revisions: $total_revisions (recommended to keep fewer than 10)" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Check traffic distribution
echo "Analyzing traffic distribution..."
traffic_distribution=$(echo "$revisions_data" | jq '[.[] | {name: .name, traffic: (.properties.trafficWeight // 0), active: .properties.active}]')
total_traffic=$(echo "$traffic_distribution" | jq '[.[] | .traffic] | add')

echo "Total traffic percentage: $total_traffic%"

if [[ "$total_traffic" != "100" && "$total_traffic" != "100.0" ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Traffic Distribution Not 100%" \
        --arg nextStep "Review and adjust traffic routing for Container App $CONTAINER_APP_NAME to ensure 100% traffic distribution." \
        --arg severity "3" \
        --arg details "Total traffic distribution: $total_traffic% (should be 100%)" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Get latest revision details
latest_revision=$(echo "$revisions_data" | jq -r 'sort_by(.properties.createdTime) | reverse | .[0]')
latest_revision_name=$(echo "$latest_revision" | jq -r '.name')
latest_active=$(echo "$latest_revision" | jq -r '.properties.active')

echo "Latest revision: $latest_revision_name (Active: $latest_active)"

# Check if latest revision is not active (might indicate deployment issues)
if [[ "$latest_active" == "false" && $active_revisions -gt 0 ]]; then
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Latest Revision Not Active" \
        --arg nextStep "Investigate why the latest revision $latest_revision_name is not active. Check for deployment or health issues." \
        --arg severity "3" \
        --arg details "Latest revision $latest_revision_name is not active while older revisions are active" \
        '.issues += [{"title": $title, "next_step": $nextStep, "severity": ($severity | tonumber), "details": $details}]'
    )
fi

# Generate revision health summary
summary_file="container_app_revision_summary.txt"
echo "Revision Health Summary for Container App: $CONTAINER_APP_NAME" > "$summary_file"
echo "=========================================================" >> "$summary_file"
echo "Total Revisions: $total_revisions" >> "$summary_file"
echo "Active Revisions: $active_revisions" >> "$summary_file"
echo "Inactive Revisions: $inactive_revisions" >> "$summary_file"
echo "Failed Provisioning: $provisioning_failed_revisions" >> "$summary_file"
echo "Unhealthy Revisions: $unhealthy_revisions" >> "$summary_file"
echo "Total Traffic Distribution: $total_traffic%" >> "$summary_file"
echo "Latest Revision: $latest_revision_name (Active: $latest_active)" >> "$summary_file"
echo "" >> "$summary_file"

# Add revision details to summary
echo "Revision Details:" >> "$summary_file"
echo "$traffic_distribution" | jq -r '.[] | "- \(.name): \(.traffic)% traffic, Active: \(.active)"' >> "$summary_file"

# Add issues to the summary
issue_count=$(echo "$issues_json" | jq '.issues | length')
echo "" >> "$summary_file"
echo "Issues Detected: $issue_count" >> "$summary_file"
echo "=========================================================" >> "$summary_file"
echo "$issues_json" | jq -r '.issues[] | "Title: \(.title)\nSeverity: \(.severity)\nDetails: \(.details)\nNext Steps: \(.next_step)\n"' >> "$summary_file"

# Save JSON outputs
issues_file="container_app_revision_issues.json"
revisions_file="container_app_revisions_data.json"

echo "$issues_json" > "$issues_file"
echo "$revisions_data" > "$revisions_file"

# Final output
echo "Summary generated at: $summary_file"
echo "Revisions data saved at: $revisions_file"
echo "Issues JSON saved at: $issues_file" 