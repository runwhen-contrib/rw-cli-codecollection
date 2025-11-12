#!/bin/bash

# Azure Subscription Cost Health Analysis Script
# Discovers stopped functions on App Service Plans, proposes consolidation ideas, and estimates costs
# Supports scoping to specific subscriptions and resource groups

set -euo pipefail

# Environment variables expected:
# AZURE_SUBSCRIPTION_IDS - Comma-separated list of subscription IDs to analyze (required)
# AZURE_RESOURCE_GROUPS - Comma-separated list of resource groups to analyze (optional, defaults to all)
# AZURE_SUBSCRIPTION_ID - Single subscription ID (for backward compatibility)
# AZURE_DISCOUNT_PERCENTAGE - Discount percentage off MSRP (optional, defaults to 0)

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

# Discount percentage (default to 0 if not set)
DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE:-0}

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

# Apply discount to a given cost
apply_discount() {
    local cost="$1"
    
    if [[ "$DISCOUNT_PERCENTAGE" -eq 0 ]]; then
        echo "$cost"
    else
        # Calculate discounted cost: cost * (1 - discount/100)
        local discount_factor=$(echo "scale=4; 1 - ($DISCOUNT_PERCENTAGE / 100)" | bc -l)
        local discounted_cost=$(echo "scale=2; $cost * $discount_factor" | bc -l)
        echo "$discounted_cost"
    fi
}

# Calculate rightsizing savings after removing stopped functions
calculate_rightsizing_savings() {
    local current_tier="$1"
    local current_sku="$2"
    local current_capacity="$3"
    local remaining_functions="$4"
    local current_monthly_cost="$5"
    
    local savings=0
    local recommendation=""
    local new_tier_sku=""
    
    # If no functions remain, recommend deletion
    if [[ $remaining_functions -eq 0 ]]; then
        savings="$current_monthly_cost"
        recommendation="Delete App Service Plan - no active functions remaining"
        new_tier_sku="DELETE"
        echo "$savings|$recommendation|$new_tier_sku"
        return
    fi
    
    # Rightsizing logic based on remaining function count and current tier
    case "$current_tier" in
        "ElasticPremium"|"Premium"|"PremiumV2"|"PremiumV3")
            if [[ $remaining_functions -le 2 ]]; then
                # Recommend downgrade to Standard S1
                local new_cost=$(apply_discount "146.00")
                savings=$(echo "scale=2; $current_monthly_cost - $new_cost" | bc -l)
                recommendation="Downgrade to Standard S1 - sufficient for $remaining_functions functions"
                new_tier_sku="Standard S1"
            elif [[ $remaining_functions -le 5 ]]; then
                # Recommend downgrade to Standard S2
                local new_cost=$(apply_discount "292.00")
                savings=$(echo "scale=2; $current_monthly_cost - $new_cost" | bc -l)
                recommendation="Downgrade to Standard S2 - sufficient for $remaining_functions functions"
                new_tier_sku="Standard S2"
            elif [[ $current_capacity -gt 1 ]]; then
                # Reduce capacity within same tier
                local new_capacity=1
                local cost_per_instance=$(get_azure_asp_cost "$current_sku" "$current_tier")
                local new_cost=$(apply_discount $(echo "scale=2; $cost_per_instance * $new_capacity" | bc -l))
                savings=$(echo "scale=2; $current_monthly_cost - $new_cost" | bc -l)
                recommendation="Reduce capacity from $current_capacity to $new_capacity instances"
                new_tier_sku="$current_tier $current_sku (1 instance)"
            else
                # Minimal savings - just removing stopped functions overhead
                savings=$(echo "scale=2; $current_monthly_cost * 0.1" | bc -l)
                recommendation="Remove stopped functions to reduce overhead"
                new_tier_sku="$current_tier $current_sku (optimized)"
            fi
            ;;
        "Standard")
            if [[ $remaining_functions -le 2 && "$current_sku" != "S1" ]]; then
                # Downgrade to S1
                local new_cost=$(apply_discount "146.00")
                savings=$(echo "scale=2; $current_monthly_cost - $new_cost" | bc -l)
                recommendation="Downgrade to Standard S1 - sufficient for $remaining_functions functions"
                new_tier_sku="Standard S1"
            elif [[ $remaining_functions -le 2 ]]; then
                # Consider Basic tier
                local new_cost=$(apply_discount "54.75")
                savings=$(echo "scale=2; $current_monthly_cost - $new_cost" | bc -l)
                recommendation="Consider Basic B1 - may be sufficient for $remaining_functions functions"
                new_tier_sku="Basic B1"
            elif [[ $current_capacity -gt 1 ]]; then
                # Reduce capacity
                local new_capacity=1
                local cost_per_instance=$(get_azure_asp_cost "$current_sku" "$current_tier")
                local new_cost=$(apply_discount $(echo "scale=2; $cost_per_instance * $new_capacity" | bc -l))
                savings=$(echo "scale=2; $current_monthly_cost - $new_cost" | bc -l)
                recommendation="Reduce capacity from $current_capacity to $new_capacity instances"
                new_tier_sku="$current_tier $current_sku (1 instance)"
            else
                # Minimal savings
                savings=$(echo "scale=2; $current_monthly_cost * 0.05" | bc -l)
                recommendation="Remove stopped functions to reduce overhead"
                new_tier_sku="$current_tier $current_sku (optimized)"
            fi
            ;;
        "Basic")
            if [[ $current_capacity -gt 1 ]]; then
                # Reduce capacity
                local new_capacity=1
                local cost_per_instance=$(get_azure_asp_cost "$current_sku" "$current_tier")
                local new_cost=$(apply_discount $(echo "scale=2; $cost_per_instance * $new_capacity" | bc -l))
                savings=$(echo "scale=2; $current_monthly_cost - $new_cost" | bc -l)
                recommendation="Reduce capacity from $current_capacity to $new_capacity instances"
                new_tier_sku="$current_tier $current_sku (1 instance)"
            else
                # Minimal savings
                savings=$(echo "scale=2; $current_monthly_cost * 0.03" | bc -l)
                recommendation="Remove stopped functions to reduce overhead"
                new_tier_sku="$current_tier $current_sku (optimized)"
            fi
            ;;
        *)
            # Default case - conservative estimate
            savings=$(echo "scale=2; $current_monthly_cost * 0.1" | bc -l)
            recommendation="Remove stopped functions and review sizing"
            new_tier_sku="$current_tier $current_sku (optimized)"
            ;;
    esac
    
    # Ensure savings are positive
    if (( $(echo "$savings < 0" | bc -l) )); then
        savings=0
    fi
    
    echo "$savings|$recommendation|$new_tier_sku"
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
    
    # Extract plan name and resource group from the plan ID
    local plan_name=$(basename "$plan_id")
    local plan_rg=$(echo "$plan_id" | sed 's|.*/resourceGroups/\([^/]*\)/.*|\1|')
    
    # Get all Function Apps in the resource group and check each one individually
    local all_function_apps=$(az functionapp list --resource-group "$plan_rg" --subscription "$subscription_id" --query "[].name" -o tsv 2>/dev/null || echo "")
    
    local matching_apps='[]'
    
    if [[ -n "$all_function_apps" ]]; then
        while read -r app_name; do
            if [[ -n "$app_name" ]]; then
                # Get the actual serverFarmId for this specific Function App
                local app_server_farm_id=$(az functionapp show --name "$app_name" --resource-group "$plan_rg" --subscription "$subscription_id" --query "serverFarmId" -o tsv 2>/dev/null || echo "")
                
                # Check if this Function App belongs to our target App Service Plan
                if [[ "$app_server_farm_id" == "$plan_id" ]]; then
                    # Get full details for this Function App
                    local app_details=$(az functionapp show --name "$app_name" --resource-group "$plan_rg" --subscription "$subscription_id" --query "{name:name, resourceGroup:resourceGroup, serverFarmId:serverFarmId, state:state, kind:kind}" -o json 2>/dev/null || echo '{}')
                    
                    if [[ "$app_details" != "{}" ]]; then
                        matching_apps=$(echo "$matching_apps" | jq ". += [$app_details]")
                    fi
                fi
            fi
        done <<< "$all_function_apps"
    fi
    
    echo "$matching_apps"
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
        
        # Use process substitution to avoid subshell
        while read -r plan_data; do
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
                while read -r app_data; do
                    local app_name=$(echo "$app_data" | jq -r '.name')
                    local app_resource_group=$(echo "$app_data" | jq -r '.resourceGroup')
                    
                    if is_function_app_stopped "$app_name" "$app_resource_group" "$subscription_id"; then
                        ((stopped_function_count++))
                    else
                        ((active_function_count++))
                    fi
                done < <(echo "$function_apps" | jq -c '.[]')
            fi
            
            # Calculate monthly cost for this plan
            local monthly_cost_per_instance=$(get_azure_asp_cost "$sku_name" "$sku_tier")
            local msrp_monthly_cost=$(echo "scale=2; $monthly_cost_per_instance * $sku_capacity" | bc -l)
            local plan_monthly_cost=$(apply_discount "$msrp_monthly_cost")
            
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
        done < <(echo "$region_plans" | jq -c '.[]')
        
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
        return
    fi
    
    
    # Extract cost data directly and generate summary - simplified approach
    # Note: The regex now handles commas in numbers (e.g., 18,804.80)
    local total_monthly=$(jq -r '[.[] | .title | capture("\\$(?<monthly>[0-9,]+\\.?[0-9]*)/month").monthly | gsub(","; "") | tonumber] | add' "$ISSUES_FILE" 2>/dev/null || echo "0")
    local total_annual=$(echo "scale=2; $total_monthly * 12" | bc -l 2>/dev/null || echo "0")
    local issue_count=$(jq length "$ISSUES_FILE" 2>/dev/null || echo "0")
    local sev2_count=$(jq '[.[] | select(.severity == 2)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    local sev3_count=$(jq '[.[] | select(.severity == 3)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    local sev4_count=$(jq '[.[] | select(.severity == 4)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    
    progress "Summary: Total monthly savings: \$$total_monthly, Issues: $issue_count"
    
    # Generate summary report
    local summary_output="=== AZURE SUBSCRIPTION COST HEALTH SUMMARY ===
Date: $(date '+%Y-%m-%d %H:%M:%S UTC')

TOTAL POTENTIAL SAVINGS:
Monthly: \$$(printf "%.2f" $total_monthly)
Annual:  \$$(printf "%.2f" $total_annual)

BREAKDOWN BY SEVERITY:
Severity 2 (High Priority >\$10k/month): $sev2_count issues
Severity 3 (Medium Priority \$2k-\$10k/month): $sev3_count issues
Severity 4 (Low Priority <\$2k/month): $sev4_count issues

TOP SAVINGS OPPORTUNITIES:
$(jq -r 'sort_by(.title | capture("\\$(?<monthly>[0-9,]+\\.?[0-9]*)/month").monthly | gsub(","; "") | tonumber) | reverse | limit(3; .[]) | "- " + .title' "$ISSUES_FILE" 2>/dev/null || echo "- No opportunities identified")

IMMEDIATE ACTIONS RECOMMENDED:
1. Review and validate all empty App Service Plans
2. Delete confirmed unused App Service Plans immediately  
3. Implement governance policies to prevent future waste
4. Set up cost alerts and regular monitoring

CLEANUP COMMANDS:
$(jq -r '.[] | "# Delete: " + (.title | split("`")[1]) + "\naz appservice plan delete --name '\''" + (.title | split("`")[1]) + "'\'' --resource-group '\''rxr-rxi-prod-cus-FunctionApps-rg'\'' --subscription '\''fa3f7777-9616-4674-8e74-dcf34fde8aa6'\'' --yes\n"' "$ISSUES_FILE" 2>/dev/null || echo "# No cleanup commands available")"
    
    # Always show the summary if we have data
    if [[ "$total_monthly" != "0" && "$issue_count" != "0" ]]; then
        log "$summary_output"
        
        # Also output to console for immediate visibility
        echo ""
        echo "🎯 COST SAVINGS SUMMARY:"
        echo "========================"
        echo "💰 Total Monthly Savings: \$$(printf "%.2f" $total_monthly)"
        echo "💰 Total Annual Savings:  \$$(printf "%.2f" $total_annual)"
        echo "📊 Issues Found: $issue_count"
        echo ""
        
        # Show top 3 biggest savings opportunities
        echo "🔥 TOP SAVINGS OPPORTUNITIES:"
        jq -r 'sort_by(.title | capture("\\$(?<monthly>[0-9,]+\\.?[0-9]*)/month").monthly | gsub(","; "") | tonumber) | reverse | limit(3; .[]) | "   • " + .title' "$ISSUES_FILE" 2>/dev/null || echo "   • No specific opportunities identified"
        echo ""
        
        echo "⚡ IMMEDIATE ACTION REQUIRED:"
        echo "   This analysis identified \$$(printf "%.0f" $total_monthly)/month in waste!"
        echo "   Annual impact: \$$(printf "%.0f" $total_annual)"
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
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        printf "Discount Applied: %s%% off MSRP\n" "$DISCOUNT_PERCENTAGE" >> "$REPORT_FILE"
    fi
    hr
    
    progress "Starting Azure Subscription Cost Health Analysis"
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        progress "Applying ${DISCOUNT_PERCENTAGE}% discount to all cost calculations"
    fi
    
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
                while read -r plan_data; do
                    analyze_app_service_plan "$plan_data" "$subscription_id" "$subscription_name"
                done < <(echo "$rg_plans" | jq -c '.[]')
                
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
            while read -r plan_data; do
                analyze_app_service_plan "$plan_data" "$subscription_id" "$subscription_name"
            done < <(echo "$all_plans" | jq -c '.[]')
            
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
        log "  ℹ️ No Function Apps found on this App Service Plan using current detection method"
        
        # DIAGNOSTIC: Let's verify what Azure actually shows for this App Service Plan
        log "  🔍 DIAGNOSTIC: Checking what Azure Portal would show..."
        
        # Method 1: Check what the Azure CLI says about apps on this plan
        local apps_on_plan=$(az appservice plan show --name "$plan_name" --resource-group "$resource_group" --subscription "$subscription_id" --query "numberOfSites" -o tsv 2>/dev/null || echo "0")
        log "  📊 Azure reports $apps_on_plan sites on this App Service Plan"
        
        # Method 1b: List ALL apps that belong to this specific App Service Plan
        log "  📋 Apps that belong to App Service Plan '$plan_name':"
        az webapp list --query "[?appServicePlanId=='$plan_id'].{name:name, kind:kind, state:state}" --subscription "$subscription_id" -o table 2>/dev/null | while read line; do
            log "    $line"
        done
        
        # Method 1c: Alternative - use different property name
        log "  📋 Apps using serverFarmId property:"
        az webapp list --query "[?serverFarmId=='$plan_id'].{name:name, kind:kind, state:state}" --subscription "$subscription_id" -o table 2>/dev/null | while read line; do
            log "    $line"
        done
        
        # Method 2: Check for Web Apps (not just Function Apps) using az webapp list
        local web_apps=$(az webapp list --resource-group "$resource_group" --subscription "$subscription_id" --query "[?serverFarmId=='$plan_id'].name" -o tsv 2>/dev/null | wc -l)
        log "  🌐 Found $web_apps Web Apps associated with this plan using az webapp list"
        
        # Method 3: List ALL apps in the resource group and their hosting plans using az webapp list
        log "  📋 All apps in resource group '$resource_group' using az webapp list:"
        local webapp_output=$(az webapp list --resource-group "$resource_group" --subscription "$subscription_id" --query "[].{name:name, kind:kind, serverFarmId:serverFarmId}" -o table 2>/dev/null)
        if [[ -n "$webapp_output" ]]; then
            echo "$webapp_output" | head -10 | while read line; do
                log "    $line"
            done
        else
            log "    No output from az webapp list"
        fi
        
        # Method 3b: Check specifically for Function Apps using az webapp list
        local function_apps_via_webapp=$(az webapp list --resource-group "$resource_group" --subscription "$subscription_id" --query "[?contains(kind, 'functionapp')].{name:name, serverFarmId:serverFarmId}" -o json 2>/dev/null || echo '[]')
        local function_count_via_webapp=$(echo "$function_apps_via_webapp" | jq length)
        log "  🔧 az webapp list found $function_count_via_webapp Function Apps"
        if [[ $function_count_via_webapp -gt 0 ]]; then
            log "  📋 Function Apps and their serverFarmId via az webapp list:"
            echo "$function_apps_via_webapp" | jq -r '.[] | "    - " + .name + " -> " + (.serverFarmId // "null")' | head -5 | while read line; do
                log "$line"
            done
        fi
        
        # Method 4: Check Function Apps with different query
        local all_function_apps_detailed=$(az functionapp list --resource-group "$resource_group" --subscription "$subscription_id" --query "[].{name:name, serverFarmId:serverFarmId, kind:kind}" -o json 2>/dev/null || echo '[]')
        local function_apps_with_plan=$(echo "$all_function_apps_detailed" | jq -r --arg plan_id "$plan_id" '[.[] | select(.serverFarmId == $plan_id)] | length')
        log "  🔧 Alternative Function App detection found: $function_apps_with_plan apps"
        
        # If we found apps using alternative methods, this is a detection bug
        if [[ $apps_on_plan -gt 0 ]] || [[ $web_apps -gt 0 ]] || [[ $function_apps_with_plan -gt 0 ]]; then
            log "  ⚠️  WARNING: App Service Plan appears to have apps but script detection failed!"
            log "  ⚠️  This indicates a bug in the Function App detection logic."
            return  # Don't report as empty if we found apps via other methods
        fi
        
        # Empty App Service Plan - potential cost savings
        if [[ "$sku_tier" != "Free" && "$sku_tier" != "Shared" ]]; then
            local monthly_cost_per_instance=$(get_azure_asp_cost "$sku_name" "$sku_tier")
            local msrp_monthly_cost=$(echo "scale=2; $monthly_cost_per_instance * $sku_capacity" | bc -l)
            local plan_monthly_cost=$(apply_discount "$msrp_monthly_cost")
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
    local msrp_monthly_cost=$(echo "scale=2; $monthly_cost_per_instance * $sku_capacity" | bc -l)
    local plan_monthly_cost=$(apply_discount "$msrp_monthly_cost")
    
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        log "  Monthly Cost: \$$plan_monthly_cost (MSRP: \$$msrp_monthly_cost, ${DISCOUNT_PERCENTAGE}% discount applied)"
    else
        log "  Monthly Cost: \$$plan_monthly_cost"
    fi
    log "  Active Functions: $active_count"
    log "  Stopped Functions: $stopped_count"
    
    # Generate issues for stopped functions
    if [[ $stopped_count -gt 0 ]]; then
        # Calculate detailed rightsizing savings after removing stopped functions
        local remaining_functions=$active_count
        local waste_percentage=$(echo "scale=2; $stopped_count / $function_app_count" | bc -l)
        
        # Calculate rightsizing opportunities
        local rightsizing_analysis=$(calculate_rightsizing_savings "$sku_tier" "$sku_name" "$sku_capacity" "$remaining_functions" "$plan_monthly_cost")
        local potential_monthly_savings=$(echo "$rightsizing_analysis" | cut -d'|' -f1)
        local rightsizing_recommendation=$(echo "$rightsizing_analysis" | cut -d'|' -f2)
        local new_tier_sku=$(echo "$rightsizing_analysis" | cut -d'|' -f3)
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
        
        add_issue "Stopped Function Apps on App Service Plan \`$plan_name\` - \$$potential_monthly_savings/month savings through rightsizing" \
                 "STOPPED FUNCTION APPS & RIGHTSIZING ANALYSIS:
- App Service Plan: $plan_name
- Resource Group: $resource_group
- Subscription: $subscription_name ($subscription_id)
- Current SKU: $sku_tier $sku_name ($sku_capacity instances)
- Location: $location
- Current Monthly Cost: \$$plan_monthly_cost
- Total Function Apps: $function_app_count
- Stopped Function Apps: $stopped_count
- Active Function Apps: $active_count

STOPPED FUNCTION APPS:
$stopped_list

RIGHTSIZING OPPORTUNITY:
- **Primary Recommendation**: $rightsizing_recommendation
- **Proposed New Configuration**: $new_tier_sku
- **Monthly Savings**: \$$potential_monthly_savings
- **Annual Savings**: \$$annual_savings
- **Waste Percentage**: $(echo "scale=1; $waste_percentage * 100" | bc -l)% (stopped functions)

COST OPTIMIZATION STRATEGY:
1. **Phase 1 - Cleanup**: 
   - Delete confirmed unused stopped Function Apps
   - Archive or migrate functions that may be needed later
   
2. **Phase 2 - Rightsizing**:
   - $rightsizing_recommendation
   - Monitor performance after changes
   - Adjust further if needed

3. **Phase 3 - Optimization**:
   - Consider Consumption plan for low-traffic functions
   - Implement auto-scaling policies
   - Set up cost monitoring and alerts

BUSINESS IMPACT:
- Immediate cost reduction: \$$potential_monthly_savings/month
- Annual budget recovery: \$$annual_savings
- Improved resource efficiency and management
- Better alignment of costs with actual usage

TECHNICAL CONSIDERATIONS:
- Test function performance in new tier before full migration
- Ensure networking and security requirements are met
- Plan for traffic spikes and scaling needs
- Consider function runtime compatibility" \
                 "$severity" \
                 "List stopped functions: az functionapp list --resource-group '$resource_group' --subscription '$subscription_id' --query \"[?state=='Stopped']\"\\nDelete stopped function: az functionapp delete --name [FUNCTION_NAME] --resource-group '$resource_group' --subscription '$subscription_id'\\nResize App Service Plan: az appservice plan update --name '$plan_name' --resource-group '$resource_group' --subscription '$subscription_id' --sku [NEW_SKU]\\nMonitor performance: az monitor metrics list --resource '$plan_id' --metric 'CpuPercentage,MemoryPercentage'"
    fi
    
    hr
}

# Run main analysis
main "$@"
