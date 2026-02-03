#!/bin/bash

# Azure Advisor Reservation Recommendations
# Queries Azure Advisor for Reserved Instance purchase recommendations
# and calculates potential savings across VMs, App Service Plans, and other resources

# Environment Variables
SUBSCRIPTION_IDS="${AZURE_SUBSCRIPTION_IDS}"
ISSUES_FILE="${ISSUES_FILE:-azure_advisor_ri_issues.json}"
REPORT_FILE="${REPORT_FILE:-azure_advisor_ri_report.txt}"

# Minimum monthly savings threshold to raise an issue (default: $100/month)
MIN_SAVINGS_THRESHOLD="${MIN_SAVINGS_THRESHOLD:-100}"

# Logging function
log() {
    echo "📊 [$(date '+%H:%M:%S')] $*" >&2
}

# Initialize output files
echo "[]" > "$ISSUES_FILE"
> "$REPORT_FILE"

log "Starting Azure Advisor Reservation Recommendations analysis..."

# Parse subscription IDs
if [[ -z "$SUBSCRIPTION_IDS" ]]; then
    # Use current subscription if none specified
    SUBSCRIPTION_IDS=$(az account show --query id -o tsv 2>/dev/null)
    if [[ -z "$SUBSCRIPTION_IDS" ]]; then
        log "ERROR: No subscription specified and unable to determine current subscription"
        exit 1
    fi
fi

IFS=',' read -ra SUBS <<< "$SUBSCRIPTION_IDS"

# Arrays to collect all recommendations
declare -a all_recommendations
total_monthly_savings=0
total_annual_savings=0
recommendation_count=0

for sub_id in "${SUBS[@]}"; do
    sub_id=$(echo "$sub_id" | xargs)  # Trim whitespace
    
    log "Analyzing subscription: $sub_id"
    
    # Set subscription context
    az account set --subscription "$sub_id" 2>/dev/null
    
    # Get subscription name for reporting
    sub_name=$(az account show --subscription "$sub_id" --query name -o tsv 2>/dev/null || echo "$sub_id")
    
    # Query Azure Advisor for Cost recommendations (category: Cost)
    # Reservation recommendations are under the Cost category
    log "Querying Azure Advisor for reservation recommendations..."
    
    advisor_recs=$(az advisor recommendation list \
        --subscription "$sub_id" \
        --category Cost \
        --query "[?contains(shortDescription.problem, 'reservation') || contains(shortDescription.problem, 'Reserved') || contains(shortDescription.solution, 'reservation') || contains(shortDescription.solution, 'Reserved') || contains(impactedField, 'Microsoft.Capacity')]" \
        -o json 2>/dev/null)
    
    if [[ -z "$advisor_recs" || "$advisor_recs" == "[]" ]]; then
        # Try alternative query for all cost recommendations
        advisor_recs=$(az advisor recommendation list \
            --subscription "$sub_id" \
            --category Cost \
            -o json 2>/dev/null)
    fi
    
    if [[ -z "$advisor_recs" || "$advisor_recs" == "[]" ]]; then
        log "  No Advisor cost recommendations found for subscription $sub_name"
        continue
    fi
    
    # Parse and filter reservation-related recommendations
    ri_recommendations=$(echo "$advisor_recs" | jq -r '
        [.[] | select(
            (.shortDescription.problem | ascii_downcase | contains("reserv")) or
            (.shortDescription.solution | ascii_downcase | contains("reserv")) or
            (.recommendationTypeId | ascii_downcase | contains("reserv")) or
            (.extendedProperties.reservedResourceType != null) or
            (.extendedProperties.term != null) or
            (.extendedProperties.savingsAmount != null)
        )]
    ' 2>/dev/null)
    
    # If no reservation-specific recommendations, check for general RI recommendations via REST API
    if [[ -z "$ri_recommendations" || "$ri_recommendations" == "[]" ]]; then
        log "  Checking Reservation Recommendations API..."
        
        # Query the Reservations Recommendations API directly
        ri_api_response=$(az rest \
            --method GET \
            --url "https://management.azure.com/subscriptions/${sub_id}/providers/Microsoft.Consumption/reservationRecommendations?api-version=2023-05-01" \
            -o json 2>/dev/null)
        
        if [[ -n "$ri_api_response" && "$ri_api_response" != "null" ]]; then
            # Parse the consumption API response
            ri_recommendations=$(echo "$ri_api_response" | jq -r '
                [.value[]? | {
                    resourceType: .properties.resourceType,
                    sku: .properties.skuProperties[0].value,
                    term: .properties.term,
                    lookBackPeriod: .properties.lookBackPeriod,
                    quantity: .properties.recommendedQuantity,
                    costWithNoReservedInstances: .properties.costWithNoReservedInstances,
                    totalCostWithReservedInstances: .properties.totalCostWithReservedInstances,
                    netSavings: .properties.netSavings,
                    firstUsageDate: .properties.firstUsageDate,
                    scope: .properties.scope,
                    location: .properties.location
                }]
            ' 2>/dev/null)
        fi
    fi
    
    # Process recommendations
    if [[ -n "$ri_recommendations" && "$ri_recommendations" != "[]" && "$ri_recommendations" != "null" ]]; then
        rec_count=$(echo "$ri_recommendations" | jq 'length' 2>/dev/null || echo "0")
        log "  Found $rec_count reservation recommendation(s)"
        
        # Process each recommendation (use process substitution to avoid subshell variable loss)
        while read -r rec; do
            # Extract fields (handle both Advisor and Consumption API formats)
            resource_type=$(echo "$rec" | jq -r '.resourceType // .extendedProperties.reservedResourceType // .impactedField // "Unknown"')
            sku=$(echo "$rec" | jq -r '.sku // .extendedProperties.sku // "N/A"')
            term=$(echo "$rec" | jq -r '.term // .extendedProperties.term // "N/A"')
            quantity=$(echo "$rec" | jq -r '.quantity // .extendedProperties.recommendedQuantity // 1')
            location=$(echo "$rec" | jq -r '.location // .extendedProperties.region // "N/A"')
            
            # Savings calculation - Azure APIs return savings over the reservation term
            net_savings=$(echo "$rec" | jq -r '.netSavings // .extendedProperties.savingsAmount // .extendedProperties.annualSavingsAmount // 0')
            cost_without_ri=$(echo "$rec" | jq -r '.costWithNoReservedInstances // 0')
            cost_with_ri=$(echo "$rec" | jq -r '.totalCostWithReservedInstances // 0')
            
            # Calculate monthly/annual savings based on term
            # Azure Consumption API netSavings = total savings over the reservation term
            # Term is typically P1Y (1 year) or P3Y (3 years)
            if [[ "$net_savings" != "0" && "$net_savings" != "null" ]]; then
                # Determine the term period in years
                term_years=1
                case "$term" in
                    P1Y|1Year|"1 Year") term_years=1 ;;
                    P3Y|3Year|"3 Year"|"3 Years") term_years=3 ;;
                    *) 
                        # Default: if term looks like it mentions 3, assume 3-year
                        if [[ "$term" == *"3"* ]]; then
                            term_years=3
                        fi
                        ;;
                esac
                
                # Calculate annual savings (divide total by term years)
                annual_savings=$(echo "scale=2; $net_savings / $term_years" | bc -l 2>/dev/null || echo "$net_savings")
                monthly_savings=$(echo "scale=2; $annual_savings / 12" | bc -l 2>/dev/null || echo "0")
            else
                monthly_savings=0
                annual_savings=0
            fi
            
            # Add to report
            echo "Subscription: $sub_name" >> "$REPORT_FILE"
            echo "  Resource Type: $resource_type" >> "$REPORT_FILE"
            echo "  SKU: $sku" >> "$REPORT_FILE"
            echo "  Location: $location" >> "$REPORT_FILE"
            echo "  Term: $term" >> "$REPORT_FILE"
            echo "  Recommended Quantity: $quantity" >> "$REPORT_FILE"
            echo "  Estimated Monthly Savings: \$${monthly_savings}" >> "$REPORT_FILE"
            echo "  Estimated Annual Savings: \$${annual_savings}" >> "$REPORT_FILE"
            echo "" >> "$REPORT_FILE"
            
            ((recommendation_count++))
            total_monthly_savings=$(echo "$total_monthly_savings + $monthly_savings" | bc -l 2>/dev/null || echo "$total_monthly_savings")
            total_annual_savings=$(echo "$total_annual_savings + $annual_savings" | bc -l 2>/dev/null || echo "$total_annual_savings")
        done < <(echo "$ri_recommendations" | jq -c '.[]' 2>/dev/null)
    fi
    
    # Also check for general cost optimization recommendations that mention reservations
    log "  Checking for additional cost recommendations..."
    
    all_cost_recs=$(az advisor recommendation list \
        --subscription "$sub_id" \
        --category Cost \
        --query "[].{problem: shortDescription.problem, solution: shortDescription.solution, impact: impact, impactedValue: impactedValue, impactedField: impactedField}" \
        -o json 2>/dev/null)
    
    if [[ -n "$all_cost_recs" && "$all_cost_recs" != "[]" ]]; then
        # Log summary of other cost recommendations
        other_count=$(echo "$all_cost_recs" | jq 'length' 2>/dev/null || echo "0")
        log "  Found $other_count total cost recommendation(s) from Advisor"
        
        # Add non-reservation cost recommendations to report for reference
        echo "=== Other Cost Optimization Recommendations ===" >> "$REPORT_FILE"
        echo "$all_cost_recs" | jq -r '.[] | "- \(.problem // "N/A"): \(.solution // "N/A") [Impact: \(.impact // "N/A")]"' >> "$REPORT_FILE" 2>/dev/null
        echo "" >> "$REPORT_FILE"
    fi
done

# Generate summary
echo "" >> "$REPORT_FILE"
echo "╔═══════════════════════════════════════════════════════════════════╗" >> "$REPORT_FILE"
echo "║   RESERVATION RECOMMENDATIONS SUMMARY                             ║" >> "$REPORT_FILE"
echo "╚═══════════════════════════════════════════════════════════════════╝" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"
echo "Total Recommendations Found: $recommendation_count" >> "$REPORT_FILE"
echo "Total Potential Monthly Savings: \$$(printf '%.2f' $total_monthly_savings)" >> "$REPORT_FILE"
echo "Total Potential Annual Savings: \$$(printf '%.2f' $total_annual_savings)" >> "$REPORT_FILE"
echo "" >> "$REPORT_FILE"

# Print report to stdout
cat "$REPORT_FILE"

# Generate issue if savings exceed threshold
if (( $(echo "$total_monthly_savings >= $MIN_SAVINGS_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
    # Determine severity based on potential savings
    if (( $(echo "$total_monthly_savings >= 5000" | bc -l 2>/dev/null || echo "0") )); then
        severity=2
    elif (( $(echo "$total_monthly_savings >= 1000" | bc -l 2>/dev/null || echo "0") )); then
        severity=3
    else
        severity=4
    fi
    
    # Format savings for display
    monthly_fmt=$(printf '%.0f' $total_monthly_savings)
    annual_fmt=$(printf '%.0f' $total_annual_savings)
    
    issue_details="AZURE ADVISOR RESERVATION RECOMMENDATIONS

Azure Advisor has identified opportunities to reduce costs through Reserved Instance purchases.

Summary:
• Total Recommendations: $recommendation_count
• Potential Monthly Savings: \$${monthly_fmt}
• Potential Annual Savings: \$${annual_fmt}

Reserved Instances provide significant discounts (up to 72%) compared to pay-as-you-go pricing
in exchange for a 1-year or 3-year commitment.

RECOMMENDATION DETAILS:
$(cat "$REPORT_FILE" | head -100)

Note: Actual savings depend on consistent usage. Review utilization patterns before purchasing."

    next_steps="NEXT STEPS:

1. Review Recommendations in Azure Portal:
   • Navigate to Azure Advisor → Cost recommendations
   • Or: Cost Management → Advisor recommendations

2. Analyze Resource Utilization:
   • Run the specialized cost optimization codebundles to verify resources are right-sized
   • Ensure resources have consistent utilization before committing to RIs
   • azure-vm-cost-optimization - Check VM utilization
   • azure-aks-cost-optimization - Check AKS node pool utilization
   • azure-appservice-cost-optimization - Check App Service Plan utilization

3. Evaluate RI Terms:
   • 1-Year: ~35-40% savings, lower commitment
   • 3-Year: ~55-72% savings, best for stable workloads

4. Purchase Reservations:
   • Azure Portal → Reservations → Add
   • Or use az CLI: az reservations reservation-order purchase

5. Monitor RI Utilization:
   • After purchase, monitor in Cost Management → Reservations
   • Ensure purchased RIs are being fully utilized"

    # Write issue JSON
    jq -n \
        --arg title "Azure RI Opportunity: \$${monthly_fmt}/month Potential Savings from Reserved Instances" \
        --arg details "$issue_details" \
        --arg next_steps "$next_steps" \
        --argjson severity "$severity" \
        '[{title: $title, details: $details, severity: $severity, next_step: $next_steps}]' \
        > "$ISSUES_FILE"
    
    log "Issue generated: \$${monthly_fmt}/month potential savings identified"
else
    log "No significant RI savings opportunities found (threshold: \$${MIN_SAVINGS_THRESHOLD}/month)"
    echo '[]' > "$ISSUES_FILE"
fi

log "Analysis complete. Report saved to: $REPORT_FILE"
