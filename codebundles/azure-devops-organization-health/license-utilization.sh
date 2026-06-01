#!/usr/bin/env bash
set -euo pipefail
# NOTE: `set -x` is intentionally NOT used (it leaks AZURE_DEVOPS_PAT into logs).
[ "${AZ_DEBUG:-0}" = "1" ] && set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   AZURE_DEVOPS_ORG
#   LICENSE_UTILIZATION_THRESHOLD (optional, default: 90)
#   AUTH_TYPE (optional, default: service_principal)
#   AZURE_DEVOPS_PAT (required if AUTH_TYPE=pat)
#
# OPTIONAL ENV VARS:
#   USER_PAGE_SIZE - page size used when paginating users (default 1000, max 10000)
#
# This script:
#   1) Analyzes license usage across the organization (ALL users, not just the
#      first 100 — user entitlements are paginated)
#   2) Checks for license capacity issues
#   3) Identifies unused or inefficient license allocation
# -----------------------------------------------------------------------------

: "${AZURE_DEVOPS_ORG:?Must set AZURE_DEVOPS_ORG}"
: "${LICENSE_UTILIZATION_THRESHOLD:=90}"
: "${AUTH_TYPE:=service_principal}"
AZURE_DEVOPS_PAT="${AZURE_DEVOPS_PAT:-${azure_devops_pat:-}}"
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_PAT}"

source "$(dirname "$0")/_az_helpers.sh"

OUTPUT_FILE="license_utilization.json"
license_json='[]'
trap 'rm -f users.json' EXIT

echo "Analyzing License Utilization..."
echo "Organization: $AZURE_DEVOPS_ORG"
echo "Utilization Threshold: $LICENSE_UTILIZATION_THRESHOLD%"

setup_azure_auth

# Get organization users and their license information.
# get_all_users paginates past the 100-row API default so large organisations
# are reported accurately.
echo "Getting user license information (paginating all users)..."
if ! users=$(get_all_users); then
    echo "ERROR: Could not get user information."
    license_json=$(echo "$license_json" | jq \
        --arg title "Failed to Get User License Information" \
        --arg details "The Member Entitlement Management API could not be queried. This usually means the identity lacks the 'Member Entitlement Management (Read)' PAT scope, or is not a Project Collection Administrator." \
        --arg severity "3" \
        --arg next_steps "Grant the PAT the 'Member Entitlement Management (Read)' scope (vso.memberentitlementmanagement) and ensure the identity has Project Collection Administrator rights, then re-run." \
        '. += [{
           "title": $title,
           "details": $details,
           "severity": ($severity | tonumber),
           "next_steps": $next_steps
         }]')
    echo "$license_json" > "$OUTPUT_FILE"
    exit 1
fi

echo "$users" > users.json
user_count=$(jq '.items | length' users.json)

# Surface incomplete pagination so license ratios are not trusted blindly.
users_partial=$(jq -r '.partial // false' users.json)
if [ "$users_partial" = "true" ]; then
    echo "WARNING: user list is incomplete (pagination stopped early); license figures are a lower bound."
    lic_details=$(ado_issue_details \
        "User pagination did not complete; license figures are a lower bound." \
        "Users analyzed (partial): $user_count" \
        "Cause: a page failed mid-pagination or the 100000-row safety cap was reached" \
        "Impact: inactive-user counts and cost estimates may be understated" \
        "API: az devops user list with USER_PAGE_SIZE=${USER_PAGE_SIZE:-1000}")
    license_json=$(echo "$license_json" | jq \
        --arg title "User List Incomplete For License Analysis" \
        --arg details "$lic_details" \
        --arg severity "3" \
        --arg next_steps "Re-run when the Member Entitlement Management API is healthy. If the org exceeds 100000 users, raise the pagination safety cap. Check for throttling." \
        '. += [{"title": $title, "details": $details, "severity": ($severity | tonumber), "next_steps": $next_steps}]')
fi

if [ "$user_count" -eq 0 ]; then
    echo "No users found."
    license_json='[{"title": "No Users Found", "details": "No users found in the organization", "severity": 2, "next_steps": "Verify user access permissions or check if organization has users"}]'
    echo "$license_json" > "$OUTPUT_FILE"
    exit 0
fi

echo "Found $user_count users. Analyzing license distribution..."

# Analyze license types and usage.
#
# Azure DevOps accountLicenseType enum maps to the marketed license names as:
#   express / professional -> "Basic"            (billed, ~$6/user/month)
#   advanced               -> "Basic + Test Plans" (billed, ~$52/user/month)
#   stakeholder            -> "Stakeholder"        (free)
# Visual Studio subscribers are NOT a distinct accountLicenseType; they carry an
# msdnLicenseType (or licensingSource == "msdn") and their access is covered by
# the VS subscription, so they are not separately billed. Counting only the
# literal "basic"/"msdn" enum values (the old logic) under-reported paid seats
# badly (e.g. 1384 "express" users showed as 0 Basic and $0 cost).
license_counts=$(jq -c '
    def lvl:    (.accessLevel.accountLicenseType // "none");
    def msdn:   (.accessLevel.msdnLicenseType   // "none");
    def licsrc: (.accessLevel.licensingSource    // "none");
    def is_vs:  ((msdn != "none") or (licsrc == "msdn"));
    reduce .items[] as $x ({basic:0, advanced:0, stakeholder:0, vs:0, other:0};
        ($x | is_vs) as $v | ($x | lvl) as $l |
        if   $l == "stakeholder"                       then .stakeholder += 1
        elif $v                                        then .vs += 1
        elif ($l == "express" or $l == "professional" or $l == "basic") then .basic += 1
        elif $l == "advanced"                          then .advanced += 1
        else .other += 1 end)
    ' users.json)
basic_users=$(echo "$license_counts" | jq -r '.basic')
advanced_users=$(echo "$license_counts" | jq -r '.advanced')
stakeholder_users=$(echo "$license_counts" | jq -r '.stakeholder')
visual_studio_users=$(echo "$license_counts" | jq -r '.vs')
other_users=$(echo "$license_counts" | jq -r '.other')

echo "License Distribution:"
echo "  Basic (express/professional): $basic_users"
echo "  Basic + Test Plans (advanced): $advanced_users"
echo "  Stakeholder (free): $stakeholder_users"
echo "  Visual Studio Subscriber (covered): $visual_studio_users"
echo "  Other/None: $other_users"

# Calculate license costs (approximate list pricing; actual contract pricing varies).
basic_cost_per_user=6       # USD per month (Basic)
advanced_cost_per_user=52   # USD per month (Basic + Test Plans)
# Stakeholder and VS-subscriber seats are not separately billed.

estimated_monthly_cost=$(( (basic_users * basic_cost_per_user) + (advanced_users * advanced_cost_per_user) ))

echo "Estimated monthly license cost: \$${estimated_monthly_cost} USD"

# Check for potential license optimization issues
license_issues=()
severity=4

# High ratio of basic users (might indicate over-licensing)
if [ "$user_count" -gt 10 ]; then
    basic_ratio=$(echo "scale=1; $basic_users * 100 / $user_count" | bc -l 2>/dev/null || echo "0")
    
    if (( $(echo "$basic_ratio >= 80" | bc -l) )); then
        license_issues+=("High ratio of Basic users (${basic_ratio}%) - consider if all need full access")
        if [ "$severity" -gt 2 ]; then severity=2; fi
    fi
fi

# Check for users with last access date (if available in the data).
# Computed with a single jq pass instead of one jq invocation per user, which
# matters a great deal for organisations with thousands of users.
#
# A user is "tracked" when lastAccessedDate is present and non-empty. Azure
# DevOps represents a never-accessed user with the epoch date (0001-01-01...),
# which sorts before the cutoff and therefore counts as inactive -- matching the
# prior per-user behaviour. Never-accessed users are the strongest candidates
# for license reclamation, so they must NOT be dropped from the counts.
ninety_days_ago=$(date -d "90 days ago" -u +"%Y-%m-%dT%H:%M:%SZ")
read -r users_with_access_info inactive_users <<<"$(jq -r \
    --arg cutoff "$ninety_days_ago" '
    [ .items[]
      | (.lastAccessedDate // "") as $la
      | select($la != "" and $la != null)
    ] as $tracked
    | "\($tracked | length) \([ $tracked[] | select(.lastAccessedDate < $cutoff) ] | length)"
    ' users.json)"
users_with_access_info=${users_with_access_info:-0}
inactive_users=${inactive_users:-0}

if [ "$users_with_access_info" -gt 0 ]; then
    echo "Users with access info: $users_with_access_info"
    echo "Inactive users (90+ days): $inactive_users"
    
    if [ "$inactive_users" -gt 0 ]; then
        inactive_ratio=$(echo "scale=1; $inactive_users * 100 / $users_with_access_info" | bc -l 2>/dev/null || echo "0")
        
        if (( $(echo "$inactive_ratio >= 20" | bc -l) )); then
            license_issues+=("${inactive_users} users inactive for 90+ days (${inactive_ratio}% of tracked users)")
            if [ "$severity" -gt 2 ]; then severity=2; fi
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
fi

# VS subscribers are detected via msdnLicenseType/licensingSource, not accountLicenseType.
# Do not warn based on Basic seat count alone — many orgs use express/professional only.
if [ "$visual_studio_users" -eq 0 ] && [ "$other_users" -gt 50 ]; then
    license_issues+=("Many entitlements ($other_users) have unrecognized license types — verify accountLicenseType mapping")
fi

if [ "$user_count" -gt 100 ]; then
    license_issues+=("Large organization ($user_count users) - recommend regular license review")
fi

# Calculate efficiency metrics
paid_users=$((basic_users + advanced_users))
total_cost_users=$paid_users

if [ "$total_cost_users" -gt 0 ]; then
    cost_per_total_user=$(echo "scale=2; $estimated_monthly_cost / $total_cost_users" | bc -l 2>/dev/null || echo "0")
    echo "Average cost per paid user: \$${cost_per_total_user}/month"
fi

# Build license analysis summary - only create issues if there are actual problems
if [ ${#license_issues[@]} -gt 0 ]; then
    issues_summary=$(IFS='; '; echo "${license_issues[*]}")
    title="License Utilization: Optimization Opportunities"
    
    lic_details=$(ado_issue_details \
        "License optimization opportunities detected." \
        "Total users: $user_count" \
        "Basic (express/professional/basic): $basic_users" \
        "Basic+Test Plans (advanced): $advanced_users" \
        "Stakeholder (free): $stakeholder_users" \
        "VS Subscriber (msdn-covered): $visual_studio_users" \
        "Other/unmapped: $other_users" \
        "Inactive 90+ days: $inactive_users (of $users_with_access_info tracked)" \
        "Estimated monthly cost (list pricing): \$${estimated_monthly_cost} USD" \
        "Findings: $issues_summary" \
        "Note: express and professional accountLicenseType values are billed as Basic (~\$6/mo); advanced is Basic+Test Plans (~\$52/mo).")
    license_json=$(echo "$license_json" | jq \
        --arg title "$title" \
        --arg total_users "$user_count" \
        --arg basic_users "$basic_users" \
        --arg stakeholder_users "$stakeholder_users" \
        --arg visual_studio_users "$visual_studio_users" \
        --arg advanced_users "$advanced_users" \
        --arg inactive_users "$inactive_users" \
        --arg estimated_monthly_cost "$estimated_monthly_cost" \
        --arg issues_summary "$issues_summary" \
        --arg details "$lic_details" \
        --arg severity "$severity" \
        '. += [{
           "title": $title,
           "total_users": ($total_users | tonumber),
           "basic_users": ($basic_users | tonumber),
           "stakeholder_users": ($stakeholder_users | tonumber),
           "visual_studio_users": ($visual_studio_users | tonumber),
           "advanced_users": ($advanced_users | tonumber),
           "inactive_users": ($inactive_users | tonumber),
           "estimated_monthly_cost_usd": ($estimated_monthly_cost | tonumber),
           "issues_summary": $issues_summary,
           "severity": ($severity | tonumber),
           "details": $details,
           "next_steps": "Review license allocation and consider optimizing user access levels. Remove inactive users and ensure appropriate license types are assigned."
         }]')
else
    echo "License utilization appears optimal - no issues detected"
fi

# Add specific recommendations based on findings
if [ "$inactive_users" -gt 0 ]; then
    inactive_details=$(ado_issue_details \
        "$inactive_users users inactive for 90+ days (includes never-accessed ADO epoch dates)." \
        "Inactive users: $inactive_users" \
        "Users with lastAccessedDate tracked: $users_with_access_info" \
        "Cutoff: 90 days before run (UTC)" \
        "Reclamation: review Member Entitlement Management in Azure DevOps > Organization Settings > Users" \
        "Cost impact: each inactive Basic seat ~\$6/mo; Basic+Test Plans ~\$52/mo")
    license_json=$(echo "$license_json" | jq \
        --arg title "Inactive User Cleanup Recommended" \
        --arg details "$inactive_details" \
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
        --arg severity "4" \
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
echo "Basic: $basic_users, Basic+Test Plans: $advanced_users, Stakeholder: $stakeholder_users, VS Subscriber: $visual_studio_users, Other: $other_users"
echo "Estimated Monthly Cost: \$${estimated_monthly_cost} USD"
echo "Inactive Users: $inactive_users"
echo ""
echo "$license_json" | jq -r '.[] | "Issue: \(.title)\nDetails: \(.details)\nSeverity: \(.severity)\n---"' 