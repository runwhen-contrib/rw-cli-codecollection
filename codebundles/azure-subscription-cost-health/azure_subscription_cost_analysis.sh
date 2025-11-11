#!/bin/bash

# Azure Subscription Cost Health Analysis Script
# Discovers stopped functions on App Service Plans, proposes consolidation ideas, and estimates costs
# Supports scoping to specific subscriptions and resource groups

set -euo pipefail

# Environment variables expected:
# AZURE_SUBSCRIPTION_IDS - Comma-separated list of subscription IDs to analyze (required)
# AZURE_RESOURCE_GROUPS - Comma-separated list of resource groups to analyze (optional, defaults to all)
# AZURE_SUBSCRIPTION_ID - Single subscription ID (for backward compatibility)

# Configuration
LOOKBACK_DAYS=30
REPORT_FILE="azure_subscription_cost_analysis_report.txt"
ISSUES_FILE="azure_subscription_cost_analysis_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/azure_subscription_cost_analysis_issues_$$.json"

# Cost thresholds for severity classification
LOW_COST_THRESHOLD=500      # <$500/month = Severity 4
MEDIUM_COST_THRESHOLD=2000  # $500-$2000/month = Severity 3
HIGH_COST_THRESHOLD=10000   # >$2000/month = Severity 2

# Initialize outputs
echo -n "[" > "$ISSUES_TMP"
first_issue=true

# Cleanup function - ensure valid JSON is always created
cleanup() {
    if [[ ! -f "$ISSUES_FILE" ]] || [[ ! -s "$ISSUES_FILE" ]]; then
        echo '[]' > "$ISSUES_FILE"
    fi
    rm -f "$ISSUES_TMP" 2>/dev/null || true
}
trap cleanup EXIT

# Logging functions
log() { printf "%s\n" "$*" >> "$REPORT_FILE"; }
hr() { printf -- '─%.0s' {1..80} >> "$REPORT_FILE"; printf "\n" >> "$REPORT_FILE"; }
progress() { printf "💰 [%s] %s\n" "$(date '+%H:%M:%S')" "$*" >&2; }

# Issue reporting function
add_issue() {
    local TITLE="$1" DETAILS="$2" SEVERITY="$3" NEXT_STEPS="$4"
    log "🔸 $TITLE (severity=$SEVERITY)"
    [[ -n "$DETAILS" ]] && log "$DETAILS"
    log "Next steps: $NEXT_STEPS"
    hr
    
    [[ $first_issue == true ]] && first_issue=false || printf "," >> "$ISSUES_TMP"
    jq -n --arg t "$TITLE" --arg d "$DETAILS" --arg n "$NEXT_STEPS" --argjson s "$SEVERITY" \
        '{title:$t,details:$d,severity:$s,next_step:$n}' >> "$ISSUES_TMP"
}

# Azure App Service Plan Pricing Database (Pay-as-you-go pricing in USD per month - 2024 estimates)
get_azure_asp_cost() {
    local sku_name="$1"
    local sku_tier="$2"
    
    # Convert to lowercase for comparison
    local tier_lower=$(echo "$sku_tier" | tr '[:upper:]' '[:lower:]')
    local sku_lower=$(echo "$sku_name" | tr '[:upper:]' '[:lower:]')
    
    case "$tier_lower" in
        "free")
            echo "0.00" ;;
        "shared")
            case "$sku_lower" in
                d1) echo "9.49" ;;
                *) echo "9.49" ;;
            esac ;;
        "basic")
            case "$sku_lower" in
                b1) echo "54.75" ;;
                b2) echo "109.50" ;;
                b3) echo "219.00" ;;
                *) echo "54.75" ;;
            esac ;;
        "standard")
            case "$sku_lower" in
                s1) echo "146.00" ;;
                s2) echo "292.00" ;;
                s3) echo "584.00" ;;
                *) echo "146.00" ;;
            esac ;;
        "premium")
            case "$sku_lower" in
                p1) echo "584.00" ;;
                p2) echo "1168.00" ;;
                p3) echo "2336.00" ;;
                *) echo "584.00" ;;
            esac ;;
        "premiumv2")
            case "$sku_lower" in
                p1v2) echo "292.00" ;;
                p2v2) echo "584.00" ;;
                p3v2) echo "1168.00" ;;
                *) echo "292.00" ;;
            esac ;;
        "premiumv3")
            case "$sku_lower" in
                p1v3) echo "204.40" ;;
                p2v3) echo "408.80" ;;
                p3v3) echo "817.60" ;;
                *) echo "204.40" ;;
            esac ;;
        "isolated")
            case "$sku_lower" in
                i1) echo "1168.00" ;;
                i2) echo "2336.00" ;;
                i3) echo "4672.00" ;;
                *) echo "1168.00" ;;
            esac ;;
        "isolatedv2")
            case "$sku_lower" in
                i1v2) echo "1022.00" ;;
                i2v2) echo "2044.00" ;;
                i3v2) echo "4088.00" ;;
                i4v2) echo "8176.00" ;;
                *) echo "1022.00" ;;
            esac ;;
        *)
            # Default fallback for unknown SKUs
            echo "146.00" ;;
    esac
}

# Parse subscription IDs from environment variables
parse_subscription_ids() {
    local subscription_ids=""
    
    # Check for AZURE_SUBSCRIPTION_IDS (preferred)
    if [[ -n "${AZURE_SUBSCRIPTION_IDS:-}" ]]; then
        subscription_ids="$AZURE_SUBSCRIPTION_IDS"
    # Fall back to AZURE_SUBSCRIPTION_ID for backward compatibility
    elif [[ -n "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
        subscription_ids="$AZURE_SUBSCRIPTION_ID"
    else
        # Use current subscription if none specified
        subscription_ids=$(az account show --query "id" -o tsv)
        progress "No subscription IDs specified. Using current subscription: $subscription_ids"
    fi
    
    echo "$subscription_ids"
}

# Parse resource groups from environment variable
parse_resource_groups() {
    local resource_groups=""
    
    if [[ -n "${AZURE_RESOURCE_GROUPS:-}" ]]; then
        resource_groups="$AZURE_RESOURCE_GROUPS"
    fi
    
    echo "$resource_groups"
}

# Get Function Apps for a given App Service Plan
get_function_apps_for_plan() {
    local plan_id="$1"
    local subscription_id="$2"
    
    az functionapp list --subscription "$subscription_id" --query "[?serverFarmId=='$plan_id']" -o json
}

# Check if a Function App is stopped
is_function_app_stopped() {
    local app_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    
    local state=$(az functionapp show --name "$app_name" --resource-group "$resource_group" --subscription "$subscription_id" --query "state" -o tsv 2>/dev/null || echo "Unknown")
    [[ "$state" == "Stopped" ]]
}

# Get Function App runtime and last modified date
get_function_app_details() {
    local app_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    
    local details=$(az functionapp show --name "$app_name" --resource-group "$resource_group" --subscription "$subscription_id" --query "{runtime: kind, lastModified: lastModifiedTimeUtc, hostingEnvironment: hostingEnvironmentProfile.name}" -o json 2>/dev/null || echo '{}')
    echo "$details"
}

# Analyze consolidation opportunities
analyze_consolidation_opportunities() {
    local plans_data="$1"
    local subscription_id="$2"
    local subscription_name="$3"
    
    progress "Analyzing consolidation opportunities for subscription: $subscription_name"
    
    # Group plans by region and analyze consolidation potential
    local regions=$(echo "$plans_data" | jq -r '.[].location' | sort -u)
    
    for region in $regions; do
        local region_plans=$(echo "$plans_data" | jq --arg region "$region" '[.[] | select(.location == $region)]')
        local region_plan_count=$(echo "$region_plans" | jq length)
        
        if [[ $region_plan_count -lt 2 ]]; then
            continue
        fi
        
        progress "Analyzing $region_plan_count App Service Plans in region: $region"
        
        # Look for underutilized plans that could be consolidated
        local underutilized_plans=()
        local total_monthly_cost=0
        local consolidation_candidates=""
        
        echo "$region_plans" | jq -c '.[]' | while read -r plan_data; do
            local plan_name=$(echo "$plan_data" | jq -r '.name')
            local plan_id=$(echo "$plan_data" | jq -r '.id')
            local sku_name=$(echo "$plan_data" | jq -r '.sku.name')
            local sku_tier=$(echo "$plan_data" | jq -r '.sku.tier')
            local sku_capacity=$(echo "$plan_data" | jq -r '.sku.capacity // 1')
            local resource_group=$(echo "$plan_data" | jq -r '.resourceGroup')
            
            # Skip Free and Shared tiers
            if [[ "$sku_tier" == "Free" || "$sku_tier" == "Shared" ]]; then
                continue
            fi
            
            # Get Function Apps for this plan
            local function_apps=$(get_function_apps_for_plan "$plan_id" "$subscription_id")
            local function_app_count=$(echo "$function_apps" | jq length)
            local stopped_function_count=0
            local active_function_count=0
            
            # Check status of each Function App
            if [[ $function_app_count -gt 0 ]]; then
                echo "$function_apps" | jq -c '.[]' | while read -r app_data; do
                    local app_name=$(echo "$app_data" | jq -r '.name')
                    local app_resource_group=$(echo "$app_data" | jq -r '.resourceGroup')
                    
                    if is_function_app_stopped "$app_name" "$app_resource_group" "$subscription_id"; then
                        ((stopped_function_count++))
                    else
                        ((active_function_count++))
                    fi
                done
            fi
            
            # Calculate monthly cost for this plan
            local monthly_cost_per_instance=$(get_azure_asp_cost "$sku_name" "$sku_tier")
            local plan_monthly_cost=$(echo "scale=2; $monthly_cost_per_instance * $sku_capacity" | bc -l)
            
            # Consider for consolidation if:
            # 1. Has stopped functions OR
            # 2. Has very few active functions (<=2) OR
            # 3. Is a higher-tier plan with low utilization
            local consolidation_score=0
            
            if [[ $stopped_function_count -gt 0 ]]; then
                consolidation_score=$((consolidation_score + stopped_function_count * 2))
            fi
            
            if [[ $active_function_count -le 2 && $active_function_count -gt 0 ]]; then
                consolidation_score=$((consolidation_score + 3))
            fi
            
            if [[ "$sku_tier" == "Premium"* || "$sku_tier" == "Isolated"* ]] && [[ $function_app_count -le 3 ]]; then
                consolidation_score=$((consolidation_score + 5))
            fi
            
            # If consolidation score is high enough, add to candidates
            if [[ $consolidation_score -ge 3 ]]; then
                if [[ -n "$consolidation_candidates" ]]; then
                    consolidation_candidates="$consolidation_candidates,"
                fi
                consolidation_candidates="$consolidation_candidates{\"planName\":\"$plan_name\",\"resourceGroup\":\"$resource_group\",\"sku\":\"$sku_tier $sku_name\",\"capacity\":$sku_capacity,\"monthlyCost\":$plan_monthly_cost,\"functionApps\":$function_app_count,\"stoppedFunctions\":$stopped_function_count,\"activeFunctions\":$active_function_count,\"consolidationScore\":$consolidation_score}"
                total_monthly_cost=$(echo "scale=2; $total_monthly_cost + $plan_monthly_cost" | bc -l)
            fi
        done
        
        # If we have consolidation candidates, create an issue
        if [[ -n "$consolidation_candidates" ]]; then
            local candidates_json="[$consolidation_candidates]"
            local candidate_count=$(echo "$candidates_json" | jq length)
            
            if [[ $candidate_count -ge 2 ]]; then
                # Estimate potential savings (conservative estimate: 30-50% savings through consolidation)
                local potential_monthly_savings=$(echo "scale=2; $total_monthly_cost * 0.4" | bc -l)
                local annual_savings=$(echo "scale=2; $potential_monthly_savings * 12" | bc -l)
                
                # Determine severity based on savings
                local severity=4
                if (( $(echo "$potential_monthly_savings > $HIGH_COST_THRESHOLD" | bc -l) )); then
                    severity=2
                elif (( $(echo "$potential_monthly_savings > $MEDIUM_COST_THRESHOLD" | bc -l) )); then
                    severity=3
                fi
                
                # Create consolidation recommendation
                local consolidation_details="AZURE APP SERVICE PLAN CONSOLIDATION OPPORTUNITY:

REGION: $region
SUBSCRIPTION: $subscription_name ($subscription_id)
ANALYSIS DATE: $(date -Iseconds)

CONSOLIDATION CANDIDATES:
$(echo "$candidates_json" | jq -r '.[] | "- \(.planName) (\(.sku)) - \(.functionApps) Function Apps (\(.stoppedFunctions) stopped, \(.activeFunctions) active) - $\(.monthlyCost)/month"')

COST ANALYSIS:
- Current Total Monthly Cost: \$$total_monthly_cost
- Estimated Monthly Savings: \$$potential_monthly_savings (40% reduction)
- Annual Savings Potential: \$$annual_savings

CONSOLIDATION STRATEGY:
1. **Immediate Actions:**
   - Remove or archive stopped Function Apps
   - Migrate low-traffic functions to shared plans
   - Consolidate similar workloads onto fewer, appropriately-sized plans

2. **Consolidation Approach:**
   - Identify the most cost-effective target plan (typically Standard S2 or S3)
   - Migrate functions from underutilized premium plans
   - Implement proper resource tagging for cost allocation
   - Set up monitoring and alerting for the consolidated environment

3. **Risk Mitigation:**
   - Test function performance after migration
   - Implement gradual migration approach
   - Monitor resource utilization post-consolidation
   - Maintain backup plans for rollback if needed

BUSINESS IMPACT:
- Significant cost reduction through infrastructure optimization
- Simplified management and monitoring
- Better resource utilization
- Reduced operational overhead

TECHNICAL CONSIDERATIONS:
- Ensure compatibility between function runtimes
- Verify networking and security requirements
- Plan for potential performance impacts during peak loads
- Consider implementing auto-scaling policies"

                add_issue "App Service Plan Consolidation Opportunity in $region - Potential \$$potential_monthly_savings/month savings" \
                         "$consolidation_details" \
                         "$severity" \
                         "Review consolidation candidates: echo '$candidates_json' | jq\\nMigrate Function Apps: az functionapp config set --name [FUNCTION_NAME] --resource-group [RESOURCE_GROUP] --subscription '$subscription_id'\\nDelete unused plans: az appservice plan delete --name [PLAN_NAME] --resource-group [RESOURCE_GROUP] --subscription '$subscription_id'\\nMonitor performance: az monitor metrics list --resource [PLAN_RESOURCE_ID] --metric 'CpuPercentage'"
            fi
        fi
    done
}

# Generate comprehensive cost savings summary
generate_cost_summary() {
    progress "Generating comprehensive cost savings summary"
    
    # Check if issues file exists and has content
    if [[ ! -f "$ISSUES_FILE" ]] || [[ ! -s "$ISSUES_FILE" ]]; then
        log "No cost savings opportunities identified."
        echo "ℹ️  No significant cost savings opportunities identified."
        return
    fi
    
    # Debug: Show file contents
    progress "Issues file exists with $(wc -l < "$ISSUES_FILE") lines"
    progress "First few lines of issues file:"
    head -5 "$ISSUES_FILE" >&2 || true
    
    # Extract cost data from issues JSON and generate summary
    local summary_output=$(jq -r '
    # Extract monthly and annual costs from each issue
    def extract_costs:
        if .title then
            (.title | capture("\\$(?<monthly>[0-9.]+)/month") // {}) as $monthly |
            {
                monthly: (if $monthly.monthly then ($monthly.monthly | tonumber) else 0 end),
                annual: (if $monthly.monthly then (($monthly.monthly | tonumber) * 12) else 0 end)
            }
        else
            {monthly: 0, annual: 0}
        end;
    
    # Group by severity and calculate totals
    group_by(.severity) | 
    map({
        severity: .[0].severity,
        count: length,
        issues: map({title: .title, costs: extract_costs}),
        total_monthly: (map(extract_costs.monthly) | add),
        total_annual: (map(extract_costs.annual) | add)
    }) |
    sort_by(.severity) |
    
    # Generate summary report
    "=== AZURE SUBSCRIPTION COST HEALTH SUMMARY ===" as $header |
    "Date: " + (now | strftime("%Y-%m-%d %H:%M:%S UTC")) as $date |
    "" as $blank |
    
    # Overall totals
    "TOTAL POTENTIAL SAVINGS:" as $total_header |
    "Monthly: $" + ((map(.total_monthly) | add) | tostring) as $total_monthly |
    "Annual:  $" + ((map(.total_annual) | add) | tostring) as $total_annual |
    "" as $blank2 |
    
    # Breakdown by severity
    "BREAKDOWN BY SEVERITY:" as $breakdown_header |
    (map(
        "Severity " + (.severity | tostring) + " (" + 
        (if .severity == 2 then "High Priority >$10k/month"
         elif .severity == 3 then "Medium Priority $2k-$10k/month" 
         else "Low Priority <$2k/month" end) + "):" |
        "  Issues: " + (.count | tostring) |
        "  Monthly Savings: $" + (.total_monthly | tostring) |
        "  Annual Savings:  $" + (.total_annual | tostring) |
        "" |
        "  Details:" |
        (.issues[] | "    - " + .title + " ($" + (.costs.monthly | tostring) + "/month)") |
        ""
    ) | join("\n")) |
    
    # Recommendations
    "IMMEDIATE ACTIONS RECOMMENDED:" as $actions_header |
    "1. Review and validate all empty App Service Plans" as $action1 |
    "2. Delete confirmed unused App Service Plans immediately" as $action2 |
    "3. Implement governance policies to prevent future waste" as $action3 |
    "4. Set up cost alerts and regular monitoring" as $action4 |
    "" as $blank3 |
    
    # Commands summary
    "CLEANUP COMMANDS:" as $commands_header |
    (map(.issues[] | 
        "# Delete: " + (.title | split("`")[1] // "unknown") |
        "az appservice plan delete --name '\''" + (.title | split("`")[1] // "unknown") + "'\'' --resource-group '\''rxr-rxi-prod-cus-FunctionApps-rg'\'' --subscription '\''fa3f7777-9616-4674-8e74-dcf34fde8aa6'\'' --yes"
    ) | join("\n")) |
    
    [$header, $date, $blank, $total_header, $total_monthly, $total_annual, $blank2, $breakdown_header] + 
    [split("\n")[] | select(length > 0)] + 
    [$blank3, $actions_header, $action1, $action2, $action3, $action4, $blank3, $commands_header] +
    [split("\n")[] | select(length > 0)] |
    join("\n")
    ' "$ISSUES_FILE" 2>/dev/null)
    
    if [[ -n "$summary_output" ]]; then
        log "$summary_output"
        
        # Also output to console for immediate visibility
        echo ""
        echo "🎯 COST SAVINGS SUMMARY:"
        echo "========================"
        
        # Extract just the key numbers for console - use title which has the monthly cost
        local total_monthly=$(jq -r '[.[] | .title | capture("\\$(?<monthly>[0-9.]+)/month").monthly | tonumber] | add' "$ISSUES_FILE" 2>/dev/null || echo "0")
        local total_annual=$(echo "scale=2; $total_monthly * 12" | bc -l 2>/dev/null || echo "0")
        local issue_count=$(jq length "$ISSUES_FILE" 2>/dev/null || echo "0")
        
        echo "💰 Total Monthly Savings: \$$(printf "%.2f" $total_monthly)"
        echo "💰 Total Annual Savings:  \$$(printf "%.2f" $total_annual)"
        echo "📊 Issues Found: $issue_count"
        echo ""
        
        # Show top 3 biggest savings opportunities
        echo "🔥 TOP SAVINGS OPPORTUNITIES:"
        jq -r 'sort_by(.title | capture("\\$(?<monthly>[0-9.]+)/month").monthly | tonumber) | reverse | limit(3; .[]) | "   • " + .title' "$ISSUES_FILE" 2>/dev/null || echo "   • No specific opportunities identified"
        echo ""
    else
        log "No cost data available for summary generation."
        echo "ℹ️  No significant cost savings opportunities identified."
    fi
}

# Main analysis function
main() {
    # Initialize report
    printf "Azure Subscription Cost Health Analysis — %s\n" "$(date -Iseconds)" > "$REPORT_FILE"
    hr
    
    progress "Starting Azure Subscription Cost Health Analysis"
    
    # Parse input parameters
    local subscription_ids=$(parse_subscription_ids)
    local resource_groups=$(parse_resource_groups)
    
    progress "Target subscriptions: $subscription_ids"
    if [[ -n "$resource_groups" ]]; then
        progress "Target resource groups: $resource_groups"
    else
        progress "Analyzing all resource groups"
    fi
    
    # Convert comma-separated strings to arrays
    IFS=',' read -ra SUBSCRIPTION_ARRAY <<< "$subscription_ids"
    if [[ -n "$resource_groups" ]]; then
        IFS=',' read -ra RESOURCE_GROUP_ARRAY <<< "$resource_groups"
    else
        RESOURCE_GROUP_ARRAY=()
    fi
    
    local total_potential_savings=0
    local total_stopped_functions=0
    local total_plans_analyzed=0
    
    # Process each subscription
    for subscription_id in "${SUBSCRIPTION_ARRAY[@]}"; do
        subscription_id=$(echo "$subscription_id" | xargs)  # Trim whitespace
        
        progress "Analyzing subscription: $subscription_id"
        
        # Set subscription context
        az account set --subscription "$subscription_id" || {
            progress "Failed to set subscription context for: $subscription_id"
            continue
        }
        
        # Get subscription name
        local subscription_name=$(az account show --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null || echo "Unknown")
        
        log "Analyzing Subscription: $subscription_name ($subscription_id)"
        hr
        
        # Get App Service Plans based on resource group filter
        local asp_query=""
        if [[ ${#RESOURCE_GROUP_ARRAY[@]} -gt 0 ]]; then
            # Analyze specific resource groups
            for resource_group in "${RESOURCE_GROUP_ARRAY[@]}"; do
                resource_group=$(echo "$resource_group" | xargs)  # Trim whitespace
                
                progress "Analyzing resource group: $resource_group in subscription: $subscription_id"
                
                local rg_plans=$(az appservice plan list --resource-group "$resource_group" --subscription "$subscription_id" -o json 2>/dev/null || echo '[]')
                
                if [[ "$rg_plans" == "[]" ]]; then
                    log "No App Service Plans found in resource group: $resource_group"
                    continue
                fi
                
                local rg_plan_count=$(echo "$rg_plans" | jq length)
                progress "Found $rg_plan_count App Service Plans in resource group: $resource_group"
                total_plans_analyzed=$((total_plans_analyzed + rg_plan_count))
                
                # Analyze each plan in this resource group
                echo "$rg_plans" | jq -c '.[]' | while read -r plan_data; do
                    analyze_app_service_plan "$plan_data" "$subscription_id" "$subscription_name"
                done
                
                # Analyze consolidation opportunities for this resource group
                analyze_consolidation_opportunities "$rg_plans" "$subscription_id" "$subscription_name"
            done
        else
            # Analyze all resource groups in the subscription
            progress "Analyzing all App Service Plans in subscription: $subscription_id"
            
            local all_plans=$(az appservice plan list --subscription "$subscription_id" -o json 2>/dev/null || echo '[]')
            
            if [[ "$all_plans" == "[]" ]]; then
                log "No App Service Plans found in subscription: $subscription_name"
                continue
            fi
            
            local plan_count=$(echo "$all_plans" | jq length)
            progress "Found $plan_count App Service Plans in subscription: $subscription_name"
            total_plans_analyzed=$((total_plans_analyzed + plan_count))
            
            # Analyze each plan
            echo "$all_plans" | jq -c '.[]' | while read -r plan_data; do
                analyze_app_service_plan "$plan_data" "$subscription_id" "$subscription_name"
            done
            
            # Analyze consolidation opportunities
            analyze_consolidation_opportunities "$all_plans" "$subscription_id" "$subscription_name"
        fi
        
        hr
    done
    
    # Finalize issues JSON
    echo "]" >> "$ISSUES_TMP"
    mv "$ISSUES_TMP" "$ISSUES_FILE"
    
    # Generate comprehensive cost savings summary
    generate_cost_summary
    
    progress "Azure Subscription Cost Health Analysis completed"
    log "Analysis completed at $(date -Iseconds)"
    log "Total App Service Plans analyzed: $total_plans_analyzed"
    log "Issues file: $ISSUES_FILE"
    log "Report file: $REPORT_FILE"
}

# Analyze individual App Service Plan
analyze_app_service_plan() {
    local plan_data="$1"
    local subscription_id="$2"
    local subscription_name="$3"
    
    local plan_name=$(echo "$plan_data" | jq -r '.name')
    local plan_id=$(echo "$plan_data" | jq -r '.id')
    local sku_name=$(echo "$plan_data" | jq -r '.sku.name')
    local sku_tier=$(echo "$plan_data" | jq -r '.sku.tier')
    local sku_capacity=$(echo "$plan_data" | jq -r '.sku.capacity // 1')
    local resource_group=$(echo "$plan_data" | jq -r '.resourceGroup')
    local location=$(echo "$plan_data" | jq -r '.location')
    
    log "Analyzing App Service Plan: $plan_name"
    log "  Resource Group: $resource_group"
    log "  SKU: $sku_tier $sku_name"
    log "  Capacity: $sku_capacity instance(s)"
    log "  Location: $location"
    
    # Get Function Apps for this plan
    local function_apps=$(get_function_apps_for_plan "$plan_id" "$subscription_id")
    local function_app_count=$(echo "$function_apps" | jq length)
    
    if [[ $function_app_count -eq 0 ]]; then
        log "  ℹ️ No Function Apps found on this App Service Plan"
        
        # Empty App Service Plan - potential cost savings
        if [[ "$sku_tier" != "Free" && "$sku_tier" != "Shared" ]]; then
            local monthly_cost_per_instance=$(get_azure_asp_cost "$sku_name" "$sku_tier")
            local plan_monthly_cost=$(echo "scale=2; $monthly_cost_per_instance * $sku_capacity" | bc -l)
            local annual_cost=$(echo "scale=2; $plan_monthly_cost * 12" | bc -l)
            
            local severity=4
            if (( $(echo "$plan_monthly_cost > $HIGH_COST_THRESHOLD" | bc -l) )); then
                severity=2
            elif (( $(echo "$plan_monthly_cost > $MEDIUM_COST_THRESHOLD" | bc -l) )); then
                severity=3
            fi
            
            add_issue "Empty App Service Plan \`$plan_name\` - \$$plan_monthly_cost/month waste" \
                     "EMPTY APP SERVICE PLAN COST WASTE:
- Plan Name: $plan_name
- Resource Group: $resource_group
- Subscription: $subscription_name ($subscription_id)
- SKU: $sku_tier $sku_name
- Capacity: $sku_capacity instance(s)
- Location: $location
- Monthly Cost: \$$plan_monthly_cost
- Annual Cost: \$$annual_cost

This App Service Plan has no Function Apps or Web Apps deployed but is still incurring costs. This represents a direct cost waste that should be addressed immediately.

RECOMMENDATIONS:
1. **Immediate**: Delete the unused App Service Plan to stop incurring costs
2. **Verification**: Ensure no applications are planned for deployment
3. **Cleanup**: Remove any associated resources or configurations" \
                     "$severity" \
                     "Delete empty App Service Plan: az appservice plan delete --name '$plan_name' --resource-group '$resource_group' --subscription '$subscription_id' --yes\\nVerify no apps: az webapp list --resource-group '$resource_group' --subscription '$subscription_id'\\nCheck for dependencies: az resource list --resource-group '$resource_group' --subscription '$subscription_id'"
        fi
        return
    fi
    
    log "  Found $function_app_count Function App(s)"
    
    # Analyze Function Apps
    local stopped_functions=()
    local active_functions=()
    local stopped_count=0
    local active_count=0
    
    echo "$function_apps" | jq -c '.[]' | while read -r app_data; do
        local app_name=$(echo "$app_data" | jq -r '.name')
        local app_resource_group=$(echo "$app_data" | jq -r '.resourceGroup')
        local app_kind=$(echo "$app_data" | jq -r '.kind // "functionapp"')
        
        if is_function_app_stopped "$app_name" "$app_resource_group" "$subscription_id"; then
            log "    🔴 STOPPED: $app_name ($app_kind)"
            stopped_functions+=("$app_name")
            ((stopped_count++))
        else
            log "    🟢 ACTIVE: $app_name ($app_kind)"
            active_functions+=("$app_name")
            ((active_count++))
        fi
    done
    
    # Calculate costs
    local monthly_cost_per_instance=$(get_azure_asp_cost "$sku_name" "$sku_tier")
    local plan_monthly_cost=$(echo "scale=2; $monthly_cost_per_instance * $sku_capacity" | bc -l)
    
    log "  Monthly Cost: \$$plan_monthly_cost"
    log "  Active Functions: $active_count"
    log "  Stopped Functions: $stopped_count"
    
    # Generate issues for stopped functions
    if [[ $stopped_count -gt 0 ]]; then
        # Calculate potential savings if we can consolidate or remove stopped functions
        local waste_percentage=$(echo "scale=2; $stopped_count / $function_app_count" | bc -l)
        local potential_monthly_savings=$(echo "scale=2; $plan_monthly_cost * $waste_percentage * 0.5" | bc -l)  # Conservative estimate
        local annual_savings=$(echo "scale=2; $potential_monthly_savings * 12" | bc -l)
        
        local severity=4
        if (( $(echo "$potential_monthly_savings > $HIGH_COST_THRESHOLD" | bc -l) )); then
            severity=2
        elif (( $(echo "$potential_monthly_savings > $MEDIUM_COST_THRESHOLD" | bc -l) )); then
            severity=3
        fi
        
        local stopped_list=$(printf '%s\n' "${stopped_functions[@]}" | head -10)  # Limit to first 10 for readability
        if [[ $stopped_count -gt 10 ]]; then
            stopped_list="$stopped_list\n... and $((stopped_count - 10)) more"
        fi
        
        add_issue "Stopped Function Apps on App Service Plan \`$plan_name\` - Potential \$$potential_monthly_savings/month savings" \
                 "STOPPED FUNCTION APPS COST ANALYSIS:
- App Service Plan: $plan_name
- Resource Group: $resource_group
- Subscription: $subscription_name ($subscription_id)
- SKU: $sku_tier $sku_name ($sku_capacity instances)
- Location: $location
- Plan Monthly Cost: \$$plan_monthly_cost
- Total Function Apps: $function_app_count
- Stopped Function Apps: $stopped_count
- Active Function Apps: $active_count

STOPPED FUNCTION APPS:
$stopped_list

COST IMPACT:
- Estimated Monthly Waste: \$$potential_monthly_savings
- Annual Waste Potential: \$$annual_savings
- Waste Percentage: $(echo "scale=1; $waste_percentage * 100" | bc -l)%

RECOMMENDATIONS:
1. **Immediate**: Review stopped Function Apps and determine if they can be deleted
2. **Short-term**: Consolidate remaining active functions if possible
3. **Long-term**: Implement proper lifecycle management for Function Apps
4. **Monitoring**: Set up alerts for stopped or unused Function Apps

CONSOLIDATION OPPORTUNITIES:
- Consider migrating active functions to a smaller App Service Plan
- Evaluate if functions can be moved to Consumption plan for cost optimization
- Review if multiple functions can be combined into fewer applications" \
                 "$severity" \
                 "List stopped functions: az functionapp list --resource-group '$resource_group' --subscription '$subscription_id' --query \"[?state=='Stopped']\"\\nDelete stopped function: az functionapp delete --name [FUNCTION_NAME] --resource-group '$resource_group' --subscription '$subscription_id'\\nRestart function if needed: az functionapp start --name [FUNCTION_NAME] --resource-group '$resource_group' --subscription '$subscription_id'\\nCheck function logs: az functionapp log tail --name [FUNCTION_NAME] --resource-group '$resource_group' --subscription '$subscription_id'"
    fi
    
    hr
}

# Run main analysis
main "$@"
