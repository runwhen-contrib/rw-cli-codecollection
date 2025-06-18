#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   LICENSE_UTILIZATION_THRESHOLD (optional, default: 90)
#
# This script:
#   1) Analyzes license usage across the organization
#   2) Checks for license capacity issues
#   3) Identifies unused or inefficient license allocation
#   4) Reports licensing optimization opportunities
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${LICENSE_UTILIZATION_THRESHOLD:=90}"

OUTPUT_FILE="license_utilization.json"
license_json='[]'

echo "Analyzing License Utilization..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Utilization Threshold: $LICENSE_UTILIZATION_THRESHOLD%"

# Ensure Azure CLI is logged in and DevOps extension is installed
if ! az extension show --name azure-devops &>/dev/null; then
    echo "Installing Azure DevOps CLI extension..."
    az extension add --name azure-devops --output none
fi

# Configure Azure DevOps CLI defaults
az devops configure --defaults organization="https://dev.azure.com/$AZURE_DEVOPS_ORG" --output none

# Get organization users and their license information
echo "Getting user license information..."
if ! users=$(az devops user list --output json 2>users_err.log); then
    err_msg=$(cat users_err.log)
    rm -f users_err.log
    
    echo "ERROR: Could not get user information."
    license_json=$(echo "$license_json" | jq \
        --arg title "Failed to Get User License Information" \
        --arg details "$err_msg" \
        --arg severity "3" \
        --arg next_steps "Check permissions to access user and licensing information" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$license_json" > "$OUTPUT_FILE"
    exit 1
fi
rm -f users_err.log

echo "$users" > users.json
user_count=$(jq '. | length' users.json)

if [ "$user_count" -eq 0 ]; then
    echo "No users found."
    license_json='[{"title": "No Users Found", "details": "No users found in the organization", "severity": 2, "next_steps": "Verify user access permissions or check if organization has users"}]'
    echo "$license_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "Found $user_count users. Analyzing license distribution..."

# Analyze license types and usage
basic_users=$(jq '[.[] | select(.accessLevel == "basic")] | length' users.json)
stakeholder_users=$(jq '[.[] | select(.accessLevel == "stakeholder")] | length' users.json)
visual_studio_users=$(jq '[.[] | select(.accessLevel == "visualStudioSubscriber")] | length' users.json)
express_users=$(jq '[.[] | select(.accessLevel == "express")] | length' users.json)
advanced_users=$(jq '[.[] | select(.accessLevel == "advanced")] | length' users.json)

echo "License Distribution:"
echo "  Basic: $basic_users"
echo "  Stakeholder: $stakeholder_users"
echo "  Visual Studio Subscriber: $visual_studio_users"
echo "  Express: $express_users"
echo "  Advanced: $advanced_users"

# Calculate license costs (approximate based on typical pricing)
# Note: These are rough estimates and actual costs may vary
basic_cost_per_user=6  # USD per month
visual_studio_cost_per_user=0  # Usually included with VS subscription
advanced_cost_per_user=10  # USD per month

estimated_monthly_cost=$(( (basic_users * basic_cost_per_user) + (advanced_users * advanced_cost_per_user) ))

echo "Estimated monthly license cost: \$${estimated_monthly_cost} USD"

# Check for potential license optimization issues
license_issues=()
severity=1

# High ratio of basic users (might indicate over-licensing)
if [ "$user_count" -gt 10 ]; then
    basic_ratio=$(echo "scale=1; $basic_users * 100 / $user_count" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$basic_ratio >= 80" | bc -l) )); then
        license_issues+=("High ratio of Basic users (${basic_ratio}%) - consider if all need full access")
        severity=2
    fi
fi

# Check for users with last access date (if available in the data)
# Note: Azure DevOps CLI doesn't always provide last access info, so we'll check what's available
inactive_users=0
users_with_access_info=0

for ((i=0; i<user_count; i++)); do
    user_json=$(jq -c ".[${i}]" users.json)
    last_accessed=$(echo "$user_json" | jq -r '.lastAccessedDate // null')
    
    if [ "$last_accessed" != "null" ] && [ -n "$last_accessed" ]; then
        users_with_access_info=$((users_with_access_info + 1))
        
        # Check if user hasn't accessed in 90 days
        ninety_days_ago=$(date -d "90 days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
        if [[ "$last_accessed" < "$ninety_days_ago" ]]; then
            inactive_users=$((inactive_users + 1))
        fi
    fi
done

if [ "$users_with_access_info" -gt 0 ]; then
    echo "Users with access info: $users_with_access_info"
    echo "Inactive users (90+ days): $inactive_users"
    
    if [ "$inactive_users" -gt 0 ]; then
        inactive_ratio=$(echo "scale=1; $inactive_users * 100 / $users_with_access_info" | bc -l 2>/dev/null || echo "0")
        
        if (( $(echo "$inactive_ratio >= 20" | bc -l) )); then
            license_issues+=("${inactive_users} users inactive for 90+ days (${inactive_ratio}% of tracked users)")
            severity=2
        fi
    fi
else
    echo "No last access information available for license optimization analysis"
fi

# Check for license capacity issues (if we can determine limits)
# This would require additional API calls to get organization billing info
# For now, we'll focus on usage patterns

# Check for unusual license distribution patterns
if [ "$stakeholder_users" -eq 0 ] && [ "$user_count" -gt 5 ]; then
    license_issues+=("No stakeholder users - consider using stakeholder licenses for view-only users")
    severity=1
fi

if [ "$visual_studio_users" -eq 0 ] && [ "$basic_users" -gt 10 ]; then
    license_issues+=("No Visual Studio subscribers detected - verify if developers have VS subscriptions")
    severity=1
fi

# Check for very high license utilization (would need billing API for actual limits)
# For now, we'll flag organizations with many users as needing review
if [ "$user_count" -gt 100 ]; then
    license_issues+=("Large organization ($user_count users) - recommend regular license review")
    severity=1
fi

# Calculate efficiency metrics
paid_users=$((basic_users + advanced_users))
total_cost_users=$paid_users

if [ "$total_cost_users" -gt 0 ]; then
    cost_per_total_user=$(echo "scale=2; $estimated_monthly_cost / $total_cost_users" | bc -l 2>/dev/null || echo "0")
    echo "Average cost per paid user: \$${cost_per_total_user}/month"
fi

# Build license analysis summary
if [ ${#license_issues[@]} -eq 0 ]; then
    issues_summary="License utilization appears optimal"
    title="License Utilization: Optimal"
else
    issues_summary=$(IFS='; '; echo "${license_issues[*]}")
    title="License Utilization: Optimization Opportunities"
fi

license_json=$(echo "$license_json" | jq \
    --arg title "$title" \
    --arg total_users "$user_count" \
    --arg basic_users "$basic_users" \
    --arg stakeholder_users "$stakeholder_users" \
    --arg visual_studio_users "$visual_studio_users" \
    --arg express_users "$express_users" \
    --arg advanced_users "$advanced_users" \
    --arg inactive_users "$inactive_users" \
    --arg estimated_monthly_cost "$estimated_monthly_cost" \
    --arg issues_summary "$issues_summary" \
    --arg severity "$severity" \
    '. += [{
       "title": $title,
       "total_users": ($total_users | tonumber),
       "basic_users": ($basic_users | tonumber),
       "stakeholder_users": ($stakeholder_users | tonumber),
       "visual_studio_users": ($visual_studio_users | tonumber),
       "express_users": ($express_users | tonumber),
       "advanced_users": ($advanced_users | tonumber),
       "inactive_users": ($inactive_users | tonumber),
       "estimated_monthly_cost_usd": ($estimated_monthly_cost | tonumber),
       "issues_summary": $issues_summary,
       "severity": ($severity | tonumber),
       "details": "Organization has \($total_users) users: \($basic_users) Basic, \($stakeholder_users) Stakeholder, \($visual_studio_users) VS Subscriber. Estimated cost: $\($estimated_monthly_cost)/month. Issues: \($issues_summary)",
       "next_steps": "Review license allocation and consider optimizing user access levels. Remove inactive users and ensure appropriate license types are assigned."
     }]')

# Add specific recommendations based on findings
if [ "$inactive_users" -gt 0 ]; then
    license_json=$(echo "$license_json" | jq \
        --arg title "Inactive User Cleanup Recommended" \
        --arg details "$inactive_users users have been inactive for 90+ days" \
        --arg severity "2" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": "Review inactive users and consider removing or downgrading their licenses to reduce costs"
         }]')
fi

if [ "$basic_users" -gt 0 ] && [ "$stakeholder_users" -eq 0 ]; then
    license_json=$(echo "$license_json" | jq \
        --arg title "Consider Stakeholder Licenses" \
        --arg details "All users have paid licenses - some might be suitable for free Stakeholder access" \
        --arg severity "1" \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": "Identify users who only need read access and convert them to Stakeholder licenses"
         }]')
fi

# Clean up temporary files
rm -f users.json

# Write final JSON
echo "$license_json" > "$OUTPUT_FILE"
echo "License utilization analysis completed. Results saved to $OUTPUT_FILE"

# Output summary to stdout
echo ""
echo "=== LICENSE UTILIZATION SUMMARY ==="
echo "Total Users: $user_count"
echo "Basic: $basic_users, Stakeholder: $stakeholder_users, VS Subscriber: $visual_studio_users"
echo "Estimated Monthly Cost: \$${estimated_monthly_cost} USD"
echo "Inactive Users: $inactive_users"
echo ""
echo "$license_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 