#!/bin/bash

# Azure App Service Plan Cost Optimization Analysis Script
# Analyzes 30-day utilization trends using Azure Monitor and provides cost savings recommendations
# with Azure App Service Plan pricing estimates

set -euo pipefail

# Environment variables expected:
# AZURE_RESOURCE_GROUP - The resource group containing the App Service Plans
# AZURE_SUBSCRIPTION_ID - The Azure subscription ID

# Get or set subscription ID
if [[ -z "${AZURE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Configuration
LOOKBACK_DAYS=30
REPORT_FILE="asp_cost_optimization_report.txt"
ISSUES_FILE="asp_cost_optimization_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/asp_cost_optimization_issues_$$.json"

# Thresholds for underutilization analysis
CPU_UNDERUTILIZATION_THRESHOLD=30    # 30% CPU usage threshold
MEMORY_UNDERUTILIZATION_THRESHOLD=40 # 40% memory usage threshold
REQUEST_UNDERUTILIZATION_THRESHOLD=20 # 20% request rate threshold

# Initialize outputs
echo -n "[" > "$ISSUES_TMP"
first_issue=true

# Cleanup function - ensure valid JSON is always created
cleanup() {
    # If script exits with error, ensure we have a valid empty JSON file
    if [[ ! -f "$ISSUES_FILE" ]] || [[ ! -s "$ISSUES_FILE" ]]; then
        echo '[]' > "$ISSUES_FILE"
    fi
    rm -f "$ISSUES_TMP" 2>/dev/null || true
}
trap cleanup EXIT

# Logging functions
log() { printf "%s\n" "$*" >> "$REPORT_FILE"; }
hr() { printf -- '─%.0s' {1..80} >> "$REPORT_FILE"; printf "\n" >> "$REPORT_FILE"; }
progress() { printf "📊 [%s] %s\n" "$(date '+%H:%M:%S')" "$*" >&2; }

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

# Calculate time range for 30 days
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
start_time=$(date -u -d "$LOOKBACK_DAYS days ago" '+%Y-%m-%dT%H:%M:%SZ')

printf "App Service Plan Cost Optimization Analysis — %s\nResource Group: %s\nSubscription: %s\nAnalysis Period: %s to %s\n" \
       "$(date -Iseconds)" "$AZURE_RESOURCE_GROUP" "$subscription" "$start_time" "$end_time" > "$REPORT_FILE"
hr

progress "Starting App Service Plan cost optimization analysis for resource group: $AZURE_RESOURCE_GROUP"

# Get all App Service Plans in the resource group
progress "Fetching App Service Plans..."
ASP_LIST=$(az appservice plan list --resource-group "$AZURE_RESOURCE_GROUP" -o json)

if [[ -z "$ASP_LIST" || "$ASP_LIST" == "[]" ]]; then
    log "❌ No App Service Plans found in resource group $AZURE_RESOURCE_GROUP"
    echo '[]' > "$ISSUES_FILE"
    progress "Analysis completed - no App Service Plans to analyze"
    exit 0
fi

log "Found $(echo "$ASP_LIST" | jq length) App Service Plan(s) in resource group $AZURE_RESOURCE_GROUP"
hr

# Process each App Service Plan
echo "$ASP_LIST" | jq -c '.[]' | while read -r plan_data; do
    PLAN_NAME=$(echo "$plan_data" | jq -r '.name')
    PLAN_ID=$(echo "$plan_data" | jq -r '.id')
    SKU_NAME=$(echo "$plan_data" | jq -r '.sku.name')
    SKU_TIER=$(echo "$plan_data" | jq -r '.sku.tier')
    SKU_CAPACITY=$(echo "$plan_data" | jq -r '.sku.capacity // 1')
    PLAN_KIND=$(echo "$plan_data" | jq -r '.kind // "app"')
    LOCATION=$(echo "$plan_data" | jq -r '.location')
    
    log "Analyzing App Service Plan: $PLAN_NAME"
    log "  SKU: $SKU_TIER $SKU_NAME"
    log "  Capacity: $SKU_CAPACITY instance(s)"
    log "  Kind: $PLAN_KIND"
    log "  Location: $LOCATION"
    
    # Skip Free and Shared tiers as they have limited scaling and cost optimization options
    if [[ "$SKU_TIER" == "Free" || "$SKU_TIER" == "Shared" ]]; then
        log "  ℹ️ Skipping Free/Shared tier - limited optimization options"
        continue
    fi
    
    # Get App Service Plan metrics for the last 30 days
    progress "Querying Azure Monitor for 30-day utilization trends for $PLAN_NAME..."
    
    # CPU utilization metrics
    CPU_METRICS=$(az monitor metrics list \
        --resource "$PLAN_ID" \
        --metric "CpuPercentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --aggregation Average Maximum \
        --interval PT1H \
        --output json 2>/dev/null || echo '{"value":[]}')
    
    # Memory utilization metrics
    MEMORY_METRICS=$(az monitor metrics list \
        --resource "$PLAN_ID" \
        --metric "MemoryPercentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --aggregation Average Maximum \
        --interval PT1H \
        --output json 2>/dev/null || echo '{"value":[]}')
    
    # HTTP request metrics
    REQUEST_METRICS=$(az monitor metrics list \
        --resource "$PLAN_ID" \
        --metric "HttpQueueLength" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --aggregation Average Maximum \
        --interval PT1H \
        --output json 2>/dev/null || echo '{"value":[]}')
    
    # Process CPU metrics
    CPU_VALUES=$(echo "$CPU_METRICS" | jq -r '.value[0].timeseries[0].data[]?.average // empty' | grep -v '^$' || echo "")
    MEMORY_VALUES=$(echo "$MEMORY_METRICS" | jq -r '.value[0].timeseries[0].data[]?.average // empty' | grep -v '^$' || echo "")
    REQUEST_VALUES=$(echo "$REQUEST_METRICS" | jq -r '.value[0].timeseries[0].data[]?.average // empty' | grep -v '^$' || echo "")
    
    # Calculate CPU statistics
    if [[ -n "$CPU_VALUES" ]]; then
        CPU_STATS=$(echo "$CPU_VALUES" | sort -n | awk '
        BEGIN { sum=0; count=0; max=0 }
        { 
            values[++count] = $1
            sum += $1
            if ($1 > max) max = $1
        }
        END {
            if (count > 0) {
                avg = sum/count
                # Calculate 95th percentile from sorted values
                p95_idx = int(count * 0.95)
                if (p95_idx < 1) p95_idx = 1
                p95 = values[p95_idx]
                printf "%.2f %.2f %.2f %d\n", avg, p95, max, count
            } else {
                print "0 0 0 0"
            }
        }')
        read -r CPU_AVG CPU_95TH CPU_MAX CPU_SAMPLES <<< "$CPU_STATS"
    else
        CPU_AVG=0; CPU_95TH=0; CPU_MAX=0; CPU_SAMPLES=0
    fi
    
    # Calculate Memory statistics
    if [[ -n "$MEMORY_VALUES" ]]; then
        MEMORY_STATS=$(echo "$MEMORY_VALUES" | sort -n | awk '
        BEGIN { sum=0; count=0; max=0 }
        { 
            values[++count] = $1
            sum += $1
            if ($1 > max) max = $1
        }
        END {
            if (count > 0) {
                avg = sum/count
                p95_idx = int(count * 0.95)
                if (p95_idx < 1) p95_idx = 1
                p95 = values[p95_idx]
                printf "%.2f %.2f %.2f %d\n", avg, p95, max, count
            } else {
                print "0 0 0 0"
            }
        }')
        read -r MEMORY_AVG MEMORY_95TH MEMORY_MAX MEMORY_SAMPLES <<< "$MEMORY_STATS"
    else
        MEMORY_AVG=0; MEMORY_95TH=0; MEMORY_MAX=0; MEMORY_SAMPLES=0
    fi
    
    # Calculate Request statistics
    if [[ -n "$REQUEST_VALUES" ]]; then
        REQUEST_STATS=$(echo "$REQUEST_VALUES" | sort -n | awk '
        BEGIN { sum=0; count=0; max=0 }
        { 
            values[++count] = $1
            sum += $1
            if ($1 > max) max = $1
        }
        END {
            if (count > 0) {
                avg = sum/count
                p95_idx = int(count * 0.95)
                if (p95_idx < 1) p95_idx = 1
                p95 = values[p95_idx]
                printf "%.2f %.2f %.2f %d\n", avg, p95, max, count
            } else {
                print "0 0 0 0"
            }
        }')
        read -r REQUEST_AVG REQUEST_95TH REQUEST_MAX REQUEST_SAMPLES <<< "$REQUEST_STATS"
    else
        REQUEST_AVG=0; REQUEST_95TH=0; REQUEST_MAX=0; REQUEST_SAMPLES=0
    fi
    
    log "  30-Day Utilization Analysis:"
    log "    CPU Average: ${CPU_AVG}%"
    log "    CPU 95th Percentile: ${CPU_95TH}%"
    log "    CPU Maximum: ${CPU_MAX}%"
    log "    Memory Average: ${MEMORY_AVG}%"
    log "    Memory 95th Percentile: ${MEMORY_95TH}%"
    log "    HTTP Queue Average: ${REQUEST_AVG}"
    log "    Data Points: $CPU_SAMPLES"
    
    # Determine if the App Service Plan is underutilized
    # Consider underutilized if both CPU and Memory 95th percentiles are below thresholds
    is_underutilized=false
    
    if (( $(echo "$CPU_95TH < $CPU_UNDERUTILIZATION_THRESHOLD" | bc -l) )) && \
       (( $(echo "$MEMORY_95TH < $MEMORY_UNDERUTILIZATION_THRESHOLD" | bc -l) )) && \
       [[ $CPU_SAMPLES -gt 100 ]]; then  # Ensure we have enough data points
        is_underutilized=true
    fi
    
    if [[ "$is_underutilized" == "true" ]]; then
        progress "Detected underutilization in App Service Plan: $PLAN_NAME"
        
        # Calculate current monthly cost
        monthly_cost_per_instance=$(get_azure_asp_cost "$SKU_NAME" "$SKU_TIER")
        current_monthly_cost=$(echo "scale=2; $monthly_cost_per_instance * $SKU_CAPACITY" | bc -l)
        
        # Determine scaling recommendation based on utilization levels
        scaling_recommendation=""
        potential_savings=0
        new_capacity=$SKU_CAPACITY
        
        # Scale down capacity if very low utilization
        if (( $(echo "$CPU_95TH < 15 && $MEMORY_95TH < 25" | bc -l) )) && [[ $SKU_CAPACITY -gt 1 ]]; then
            # Can reduce capacity by 50%
            new_capacity=$(( (SKU_CAPACITY + 1) / 2 ))  # Round up division
            [[ $new_capacity -lt 1 ]] && new_capacity=1
            scaling_recommendation="Scale down from $SKU_CAPACITY to $new_capacity instances"
        elif (( $(echo "$CPU_95TH < 25 && $MEMORY_95TH < 35" | bc -l) )) && [[ $SKU_CAPACITY -gt 1 ]]; then
            # Can reduce capacity by 25%
            new_capacity=$(( (SKU_CAPACITY * 3 + 3) / 4 ))  # 75% of current, rounded up
            [[ $new_capacity -lt 1 ]] && new_capacity=1
            scaling_recommendation="Scale down from $SKU_CAPACITY to $new_capacity instances"
        fi
        
        # Consider tier downgrade for consistently low utilization
        tier_recommendation=""
        if (( $(echo "$CPU_95TH < 20 && $MEMORY_95TH < 30" | bc -l) )); then
            case "$SKU_TIER" in
                "Premium"|"PremiumV2"|"PremiumV3")
                    tier_recommendation="Consider downgrading to Standard tier"
                    ;;
                "Standard")
                    tier_recommendation="Consider downgrading to Basic tier"
                    ;;
                "Basic")
                    if [[ "$SKU_NAME" == "B3" || "$SKU_NAME" == "B2" ]]; then
                        tier_recommendation="Consider downgrading to B1"
                    fi
                    ;;
            esac
        fi
        
        # Calculate potential savings from capacity reduction
        if [[ $new_capacity -lt $SKU_CAPACITY ]]; then
            capacity_savings=$(echo "scale=2; ($SKU_CAPACITY - $new_capacity) * $monthly_cost_per_instance" | bc -l)
            potential_savings=$(echo "scale=2; $potential_savings + $capacity_savings" | bc -l)
        fi
        
        # Estimate tier downgrade savings (approximate)
        tier_savings=0
        if [[ -n "$tier_recommendation" ]]; then
            case "$SKU_TIER" in
                "Premium"|"PremiumV2"|"PremiumV3")
                    # Estimate 50% savings moving to Standard
                    tier_savings=$(echo "scale=2; $current_monthly_cost * 0.5" | bc -l)
                    ;;
                "Standard")
                    # Estimate 60% savings moving to Basic
                    tier_savings=$(echo "scale=2; $current_monthly_cost * 0.6" | bc -l)
                    ;;
                "Basic")
                    # Estimate 25% savings within Basic tier
                    tier_savings=$(echo "scale=2; $current_monthly_cost * 0.25" | bc -l)
                    ;;
            esac
        fi
        
        # Use the higher of capacity or tier savings (not both, as they're alternatives)
        if (( $(echo "$tier_savings > $potential_savings" | bc -l) )); then
            potential_savings=$tier_savings
            primary_recommendation="$tier_recommendation"
        else
            primary_recommendation="$scaling_recommendation"
        fi
        
        # Skip if no meaningful savings
        if (( $(echo "$potential_savings < 10" | bc -l) )); then
            log "  ℹ️ Minimal cost savings potential (< $10/month)"
            continue
        fi
        
        annual_savings=$(echo "scale=2; $potential_savings * 12" | bc -l)
        
        # Determine severity based on savings bands
        severity=4
        if (( $(echo "$potential_savings > 10000" | bc -l) )); then
            severity=2  # >$10k/month
        elif (( $(echo "$potential_savings > 2000" | bc -l) )); then
            severity=3  # $2k-$10k/month
        else
            severity=4  # <$2k/month
        fi
        
        log "  💰 Cost Savings Opportunity Detected!"
        log "    Current Monthly Cost: \$${current_monthly_cost}"
        log "    Potential Monthly Savings: \$${potential_savings}"
        log "    Severity Level: $severity"
        
        add_issue "Possible Cost Savings: App Service Plan \`$PLAN_NAME\` underutilized in resource group \`$AZURE_RESOURCE_GROUP\`" \
                  "AZURE APP SERVICE PLAN UNDERUTILIZATION COST ANALYSIS:
- App Service Plan: $PLAN_NAME
- Resource Group: $AZURE_RESOURCE_GROUP
- Current SKU: $SKU_TIER $SKU_NAME
- Current Capacity: $SKU_CAPACITY instance(s)
- Location: $LOCATION

30-DAY UTILIZATION TRENDS:
- CPU Average: ${CPU_AVG}%
- CPU 95th Percentile: ${CPU_95TH}%
- CPU Maximum: ${CPU_MAX}%
- Memory Average: ${MEMORY_AVG}%
- Memory 95th Percentile: ${MEMORY_95TH}%
- HTTP Queue Average: ${REQUEST_AVG}
- Analysis Period: $LOOKBACK_DAYS days
- Data Points: $CPU_SAMPLES samples
- Current Monthly Cost: \$$current_monthly_cost

COST SAVINGS OPPORTUNITY:
- Primary Recommendation: $primary_recommendation
- **Estimated Monthly Savings: \$$potential_savings**
- **Annual Savings Potential: \$$annual_savings**

UNDERUTILIZATION ANALYSIS:
This App Service Plan shows consistently low utilization over the past 30 days. The 95th percentile CPU usage of ${CPU_95TH}% and memory usage of ${MEMORY_95TH}% indicate that even during peak periods, the plan is significantly underutilized. This suggests:

1. Over-provisioned infrastructure relative to actual workload demands
2. Opportunity for cost optimization through rightsizing or tier downgrade
3. Potential for workload consolidation
4. Room for implementing auto-scaling policies

BUSINESS IMPACT:
- Unnecessary infrastructure costs of approximately \$$potential_savings per month
- Inefficient resource allocation across the App Service environment
- Opportunity for budget reallocation to higher-value initiatives
- Environmental impact from unused compute resources

RECOMMENDATIONS:
1. **Immediate**: Review application resource usage patterns and requirements
2. **Short-term**: $primary_recommendation
3. **Long-term**: Implement auto-scaling and right-sizing policies
4. **Monitoring**: Set up utilization alerts and regular cost reviews

RISK ASSESSMENT:
- Low risk for gradual scaling down with proper monitoring
- Ensure adequate headroom for traffic spikes and application growth
- Test scaling changes in staging environments first
- Monitor application performance during optimization" $severity \
                  "Review App Service Plan metrics: az monitor metrics list --resource '$PLAN_ID' --metric 'CpuPercentage'\\nScale App Service Plan: az appservice plan update --name '$PLAN_NAME' --resource-group '$AZURE_RESOURCE_GROUP' --number-of-workers $new_capacity\\nUpdate App Service Plan SKU: az appservice plan update --name '$PLAN_NAME' --resource-group '$AZURE_RESOURCE_GROUP' --sku [NEW_SKU]\\nAnalyze app performance: az webapp log tail --name [APP_NAME] --resource-group '$AZURE_RESOURCE_GROUP'\\nReview app settings: az webapp config show --name [APP_NAME] --resource-group '$AZURE_RESOURCE_GROUP'"
    else
        log "  ✅ App Service Plan utilization is within acceptable range"
    fi
    
    hr
done

# Finalize issues JSON
echo "]" >> "$ISSUES_TMP"
mv "$ISSUES_TMP" "$ISSUES_FILE"

progress "App Service Plan cost optimization analysis completed"
log "Analysis completed at $(date -Iseconds)"
log "Issues file: $ISSUES_FILE"
log "Report file: $REPORT_FILE"
