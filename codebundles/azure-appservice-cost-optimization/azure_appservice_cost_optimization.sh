#!/bin/bash

# Azure App Service Cost Optimization Analysis
# Focus: Recommend cost savings for App Service Plans
#
# Performance Features:
#   - Azure Resource Graph for 10-100x faster plan discovery
#   - Parallel metrics collection with controlled concurrency
#   - Scan modes: full (default), quick, sample

set -eo pipefail  # Removed 'u' to allow undefined variables, keep 'e' for error exit and 'o pipefail' for pipe errors

# Source shared performance utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../libraries/Azure/azure_performance_utils.sh" 2>/dev/null || \
source "/home/runwhen/codecollection/libraries/Azure/azure_performance_utils.sh" 2>/dev/null || {
    echo "Warning: Performance utilities not found, using standard queries" >&2
}

# Configuration
SUBSCRIPTION_IDS="${AZURE_SUBSCRIPTION_IDS:-}"
RESOURCE_GROUPS="${AZURE_RESOURCE_GROUPS:-}"

# Sanitize RESOURCE_GROUPS: Robot Framework sometimes passes '""' or "''" as literal strings
# Treat these as empty to trigger auto-discovery
if [[ "$RESOURCE_GROUPS" == '""' ]] || [[ "$RESOURCE_GROUPS" == "''" ]] || [[ "$RESOURCE_GROUPS" == '""""""' ]]; then
    RESOURCE_GROUPS=""
fi
# Also trim whitespace
RESOURCE_GROUPS=$(echo "$RESOURCE_GROUPS" | xargs)

ISSUES_FILE="azure_appservice_cost_optimization_issues.json"
REPORT_FILE="azure_appservice_cost_optimization_report.txt"
DETAILS_FILE="azure_appservice_cost_optimization_details.json"  # Detailed findings, grouped issues go to ISSUES_FILE

# Cost impact thresholds (monthly savings in USD) - configurable via environment variables
# These control how recommendations are grouped in issues by potential savings amount:
# - HIGH Savings: >= HIGH_COST_THRESHOLD (creates Severity 2 issue)
# - MEDIUM Savings: >= MEDIUM_COST_THRESHOLD and < HIGH_COST_THRESHOLD (creates Severity 3 issue)  
# - LOW Savings: < MEDIUM_COST_THRESHOLD (creates Severity 4 issue)
LOW_COST_THRESHOLD="${LOW_COST_THRESHOLD:-0}"        # Reserved for future use
MEDIUM_COST_THRESHOLD="${MEDIUM_COST_THRESHOLD:-2000}"
HIGH_COST_THRESHOLD="${HIGH_COST_THRESHOLD:-10000}"

# Optimization Strategy: aggressive, balanced, or conservative
# - aggressive: Maximum cost savings, minimal headroom (15-20% target utilization increase)
# - balanced: Moderate savings with reasonable headroom (default, 25-30% target)
# - conservative: Safe optimizations with ample headroom (35-40% target, preserve burst capacity)
OPTIMIZATION_STRATEGY="${OPTIMIZATION_STRATEGY:-balanced}"

# Cleanup function to remove temporary files and cache directories
cleanup() {
    # Ensure issues file exists
    if [[ ! -f "$ISSUES_FILE" ]] || [[ ! -s "$ISSUES_FILE" ]]; then
        echo '[]' > "$ISSUES_FILE"
    fi
    # Clean up performance utilities cache directory
    azure_perf_cleanup 2>/dev/null || true
}
trap cleanup EXIT

# Logging function
log() {
    echo "💰 [$(date +'%H:%M:%S')] $*" >&2
}

# Get Function Apps for a given App Service Plan - OPTIMIZED VERSION
get_apps_for_plan() {
    local plan_id="$1"
    local subscription_id="$2"
    
    log "  Fetching apps for plan (optimized batch query)..."
    
    # Query both web apps AND function apps (they're separate in Azure CLI)
    # Use Azure CLI's JMESPath filtering which handles case-insensitive ID matching
    local web_apps=$(az webapp list \
        --subscription "$subscription_id" \
        --query "[?appServicePlanId=='$plan_id'].{name:name, resourceGroup:resourceGroup, serverFarmId:appServicePlanId, state:state, kind:kind}" \
        -o json 2>/dev/null || echo '[]')
    
    local function_apps=$(az functionapp list \
        --subscription "$subscription_id" \
        --query "[?appServicePlanId=='$plan_id'].{name:name, resourceGroup:resourceGroup, serverFarmId:appServicePlanId, state:state, kind:kind}" \
        -o json 2>/dev/null || echo '[]')
    
    # Merge both arrays
    local matching_apps=$(jq -s '.[0] + .[1]' <(echo "$web_apps") <(echo "$function_apps"))
    
    local matched=$(echo "$matching_apps" | jq 'length')
    
    # Get total counts for context
    local total_web=$(az webapp list --subscription "$subscription_id" --query "length(@)" -o tsv 2>/dev/null || echo "0")
    local total_func=$(az functionapp list --subscription "$subscription_id" --query "length(@)" -o tsv 2>/dev/null || echo "0")
    local total_apps=$((total_web + total_func))
    
    log "  ✓ Batch query completed: found $matched apps on this plan (out of $total_apps total apps: $total_web web + $total_func function)"
    echo "$matching_apps"
}

# Get metrics for App Service Plan - OPTIMIZED VERSION
get_plan_metrics() {
    local plan_id="$1"
    local subscription_id="$2"
    
    log "  Querying metrics (7 days, this may take 15-30 seconds)..."
    
    # Get last 7 days of metrics
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d '7 days ago' +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    
    # OPTIMIZATION: Query both metrics in parallel using background processes
    local cpu_metrics_file=$(mktemp)
    local memory_metrics_file=$(mktemp)
    
    # Start both queries in parallel
    (az monitor metrics list \
        --resource "$plan_id" \
        --metric "CpuPercentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average Maximum \
        --subscription "$subscription_id" \
        -o json 2>/dev/null || echo '{}') > "$cpu_metrics_file" &
    local cpu_pid=$!
    
    (az monitor metrics list \
        --resource "$plan_id" \
        --metric "MemoryPercentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average Maximum \
        --subscription "$subscription_id" \
        -o json 2>/dev/null || echo '{}') > "$memory_metrics_file" &
    local mem_pid=$!
    
    # Wait for both queries to complete
    wait $cpu_pid 2>/dev/null
    wait $mem_pid 2>/dev/null
    
    log "  ✓ Metrics queries completed"
    
    # Read results
    local cpu_metrics=$(cat "$cpu_metrics_file")
    local memory_metrics=$(cat "$memory_metrics_file")
    
    # Cleanup temp files
    rm -f "$cpu_metrics_file" "$memory_metrics_file"
    
    # Extract average and max values - convert to integers for bash comparison
    local cpu_avg=$(echo "$cpu_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.average != null) | .average' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print "0"}')
    local cpu_max=$(echo "$cpu_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.maximum != null) | .maximum' 2>/dev/null | sort -rn | head -1 | awk '{print int($1+0.5)}')  # Round to nearest int
    
    local mem_avg=$(echo "$memory_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.average != null) | .average' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print "0"}')
    local mem_max=$(echo "$memory_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.maximum != null) | .maximum' 2>/dev/null | sort -rn | head -1 | awk '{print int($1+0.5)}')  # Round to nearest int
    
    # Default to 0 if empty or invalid
    cpu_avg=${cpu_avg:-0}
    cpu_max=${cpu_max:-0}
    mem_avg=${mem_avg:-0}
    mem_max=${mem_max:-0}
    
    # Ensure they're integers (strip any remaining decimals)
    cpu_avg=$(echo "$cpu_avg" | awk '{print int($1)}')
    cpu_max=$(echo "$cpu_max" | awk '{print int($1)}')
    mem_avg=$(echo "$mem_avg" | awk '{print int($1)}')
    mem_max=$(echo "$mem_max" | awk '{print int($1)}')
    
    # Final safety check
    [[ -z "$cpu_avg" || ! "$cpu_avg" =~ ^[0-9]+$ ]] && cpu_avg=0
    [[ -z "$cpu_max" || ! "$cpu_max" =~ ^[0-9]+$ ]] && cpu_max=0
    [[ -z "$mem_avg" || ! "$mem_avg" =~ ^[0-9]+$ ]] && mem_avg=0
    [[ -z "$mem_max" || ! "$mem_max" =~ ^[0-9]+$ ]] && mem_max=0
    
    echo "$cpu_avg|$cpu_max|$mem_avg|$mem_max"
}

# Calculate App Service Plan cost
calculate_plan_cost() {
    local sku_tier="$1"
    local sku_name="$2" 
    local sku_capacity="$3"
    
    local base_cost=0
    
    # Pricing based on Azure pricing (approximate USD/month, US regions)
    # Normalize SKU name to uppercase for matching
    local sku_upper=$(echo "$sku_name" | tr '[:lower:]' '[:upper:]')
    
    case "$sku_tier" in
        "Free")
            base_cost=0
            ;;
        "Shared"|"Dynamic")
            base_cost=10
            ;;
        "Basic")
            case "$sku_upper" in
                "B1") base_cost=55 ;;
                "B2") base_cost=109 ;;
                "B3") base_cost=219 ;;
                *) base_cost=55 ;;  # Default to B1
            esac
            ;;
        "Standard")
            case "$sku_upper" in
                "S1") base_cost=73 ;;
                "S2") base_cost=146 ;;
                "S3") base_cost=292 ;;
                *) base_cost=73 ;;  # Default to S1
            esac
            ;;
        "Premium")
            case "$sku_upper" in
                "P1") base_cost=146 ;;
                "P2") base_cost=292 ;;
                "P3") base_cost=584 ;;
                *) base_cost=146 ;;  # Default to P1
            esac
            ;;
        "PremiumV2")
            case "$sku_upper" in
                "P1V2") base_cost=146 ;;
                "P2V2") base_cost=292 ;;
                "P3V2") base_cost=584 ;;
                *) base_cost=146 ;;  # Default to P1v2
            esac
            ;;
        "PremiumV3")
            case "$sku_upper" in
                "P0V3") base_cost=78 ;;
                "P1V3") base_cost=146 ;;
                "P2V3") base_cost=292 ;;
                "P3V3") base_cost=584 ;;
                "P1MV3") base_cost=292 ;;
                "P2MV3") base_cost=584 ;;
                "P3MV3") base_cost=1168 ;;
                "P4MV3") base_cost=2336 ;;
                "P5MV3") base_cost=4672 ;;
                *) base_cost=146 ;;  # Default to P1v3
            esac
            ;;
        "ElasticPremium"|"FlexConsumption")
            case "$sku_upper" in
                "EP1") base_cost=146 ;;
                "EP2") base_cost=292 ;;
                "EP3") base_cost=584 ;;
                "FC1") base_cost=175 ;;  # Flex Consumption
                *) base_cost=146 ;;  # Default to EP1
            esac
            ;;
        "Isolated")
            case "$sku_upper" in
                "I1") base_cost=298 ;;
                "I2") base_cost=595 ;;
                "I3") base_cost=1190 ;;
                *) base_cost=298 ;;  # Default to I1
            esac
            ;;
        "IsolatedV2")
            case "$sku_upper" in
                "I1V2") base_cost=298 ;;
                "I2V2") base_cost=595 ;;
                "I3V2") base_cost=1190 ;;
                "I4V2") base_cost=2380 ;;
                "I5V2") base_cost=4760 ;;
                "I6V2") base_cost=9520 ;;
                *) base_cost=298 ;;  # Default to I1v2
            esac
            ;;
        "WorkflowStandard")
            # Logic Apps Standard
            case "$sku_upper" in
                "WS1") base_cost=151 ;;
                "WS2") base_cost=302 ;;
                "WS3") base_cost=605 ;;
                *) base_cost=151 ;;  # Default to WS1
            esac
            ;;
        *)
            # Try to determine by SKU name pattern if tier is unknown
            case "$sku_upper" in
                B1|B2|B3) 
                    case "$sku_upper" in
                        "B1") base_cost=55 ;;
                        "B2") base_cost=109 ;;
                        "B3") base_cost=219 ;;
                    esac
                    ;;
                S1|S2|S3)
                    case "$sku_upper" in
                        "S1") base_cost=73 ;;
                        "S2") base_cost=146 ;;
                        "S3") base_cost=292 ;;
                    esac
                    ;;
                P1|P2|P3|P1V2|P2V2|P3V2|P0V3|P1V3|P2V3|P3V3)
                    case "$sku_upper" in
                        "P1"|"P1V2"|"P1V3") base_cost=146 ;;
                        "P2"|"P2V2"|"P2V3") base_cost=292 ;;
                        "P3"|"P3V2"|"P3V3") base_cost=584 ;;
                        "P0V3") base_cost=78 ;;
                    esac
                    ;;
                P1MV3|P2MV3|P3MV3|P4MV3|P5MV3)
                    case "$sku_upper" in
                        "P1MV3") base_cost=292 ;;
                        "P2MV3") base_cost=584 ;;
                        "P3MV3") base_cost=1168 ;;
                        "P4MV3") base_cost=2336 ;;
                        "P5MV3") base_cost=4672 ;;
                    esac
                    ;;
                EP1|EP2|EP3)
                    case "$sku_upper" in
                        "EP1") base_cost=146 ;;
                        "EP2") base_cost=292 ;;
                        "EP3") base_cost=584 ;;
                    esac
                    ;;
                I1|I2|I3|I1V2|I2V2|I3V2|I4V2|I5V2|I6V2)
                    case "$sku_upper" in
                        "I1"|"I1V2") base_cost=298 ;;
                        "I2"|"I2V2") base_cost=595 ;;
                        "I3"|"I3V2") base_cost=1190 ;;
                        "I4V2") base_cost=2380 ;;
                        "I5V2") base_cost=4760 ;;
                        "I6V2") base_cost=9520 ;;
                    esac
                    ;;
                Y1)
                    # Consumption plan - charge per execution, estimate minimal base
                    base_cost=0
                    ;;
                *)
                    # Unknown SKU - log warning and estimate based on capacity
                    log "  ⚠️  Unknown SKU '$sku_tier/$sku_name' - using estimate"
                    base_cost=100  # Conservative estimate
                    ;;
            esac
            ;;
    esac
    
    echo $((base_cost * sku_capacity))
}

# Generate all optimization options with context and risk assessment
generate_optimization_options() {
    local current_tier="$1"
    local current_name="$2"
    local current_capacity="$3"
    local app_count="$4"
    local running_apps="$5"
    local cpu_avg="$6"
    local cpu_max="$7"
    local mem_avg="$8"
    local mem_max="$9"
    
    # Calculate projected utilization after changes
    # Format: option_id|tier|name|capacity|description|risk_level|projected_cpu_avg|projected_cpu_max|projected_mem_avg|projected_mem_max|confidence
    # Fields:     1        2    3      4         5          6            7                8               9               10              11
    local options=""
    
    # Option 1: Keep current (baseline)
    options+="CURRENT|$current_tier|$current_name|$current_capacity|Keep current configuration - No changes|NONE|$cpu_avg|$cpu_max|$mem_avg|$mem_max|100\n"
    
    # Calculate potential capacity reductions
    if [[ $current_capacity -gt 1 ]]; then
        # Option: Reduce capacity by 1 instance
        local new_cap_minus1=$((current_capacity - 1))
        local proj_cpu_avg_minus1=$(( (cpu_avg * current_capacity) / new_cap_minus1 ))
        local proj_cpu_max_minus1=$(( (cpu_max * current_capacity) / new_cap_minus1 ))
        local proj_mem_avg_minus1=$(( (mem_avg * current_capacity) / new_cap_minus1 ))
        local proj_mem_max_minus1=$(( (mem_max * current_capacity) / new_cap_minus1 ))
        
        # Cap at 100%
        [[ $proj_cpu_avg_minus1 -gt 100 ]] && proj_cpu_avg_minus1=100
        [[ $proj_cpu_max_minus1 -gt 100 ]] && proj_cpu_max_minus1=100
        [[ $proj_mem_avg_minus1 -gt 100 ]] && proj_mem_avg_minus1=100
        [[ $proj_mem_max_minus1 -gt 100 ]] && proj_mem_max_minus1=100
        
        local risk_minus1="LOW"
        local confidence_minus1=85
        # Check both CPU and Memory for risk assessment
        [[ $proj_cpu_max_minus1 -gt 80 || $proj_mem_max_minus1 -gt 85 ]] && risk_minus1="MEDIUM" && confidence_minus1=70
        [[ $proj_cpu_max_minus1 -gt 90 || $proj_mem_max_minus1 -gt 95 ]] && risk_minus1="HIGH" && confidence_minus1=50
        # If current memory is already very high, any reduction is risky
        [[ $mem_max -gt 90 ]] && risk_minus1="HIGH" && confidence_minus1=45
        
        options+="SCALE_DOWN_1|$current_tier|$current_name|$new_cap_minus1|Reduce capacity by 1 instance|$risk_minus1|$proj_cpu_avg_minus1|$proj_cpu_max_minus1|$proj_mem_avg_minus1|$proj_mem_max_minus1|$confidence_minus1\n"
        
        # Option: Reduce capacity by 50%
        if [[ $current_capacity -gt 2 ]]; then
            local new_cap_half=$(( (current_capacity + 1) / 2 ))
            local proj_cpu_avg_half=$(( (cpu_avg * current_capacity) / new_cap_half ))
            local proj_cpu_max_half=$(( (cpu_max * current_capacity) / new_cap_half ))
            local proj_mem_avg_half=$(( (mem_avg * current_capacity) / new_cap_half ))
            local proj_mem_max_half=$(( (mem_max * current_capacity) / new_cap_half ))
            
            [[ $proj_cpu_avg_half -gt 100 ]] && proj_cpu_avg_half=100
            [[ $proj_cpu_max_half -gt 100 ]] && proj_cpu_max_half=100
            [[ $proj_mem_avg_half -gt 100 ]] && proj_mem_avg_half=100
            [[ $proj_mem_max_half -gt 100 ]] && proj_mem_max_half=100
            
            local risk_half="MEDIUM"
            local confidence_half=70
            # Check both CPU and Memory for risk assessment
            [[ $proj_cpu_max_half -gt 85 || $proj_mem_max_half -gt 90 ]] && risk_half="HIGH" && confidence_half=50
            [[ $proj_cpu_max_half -lt 75 && $proj_mem_max_half -lt 80 ]] && risk_half="LOW" && confidence_half=80
            # If current memory is already very high, 50% reduction is very risky
            [[ $mem_max -gt 85 ]] && risk_half="HIGH" && confidence_half=40
            
            options+="SCALE_DOWN_50|$current_tier|$current_name|$new_cap_half|Reduce capacity by 50%|$risk_half|$proj_cpu_avg_half|$proj_cpu_max_half|$proj_mem_avg_half|$proj_mem_max_half|$confidence_half\n"
        fi
    fi
    
    # SKU downsizing options
    local downgrade_sku=""
    local downgrade_tier="$current_tier"
    
    if [[ "$current_name" == "P3v3" ]]; then
        downgrade_sku="P2v3"
    elif [[ "$current_name" == "P3v2" ]]; then
        downgrade_sku="P2v2"
    elif [[ "$current_name" == "P2v3" ]]; then
        downgrade_sku="P1v3"
    elif [[ "$current_name" == "P2v2" ]]; then
        downgrade_sku="P1v2"
    elif [[ "$current_name" == "EP3" ]]; then
        downgrade_sku="EP2"
        downgrade_tier="ElasticPremium"
    elif [[ "$current_name" == "EP2" ]]; then
        downgrade_sku="EP1"
        downgrade_tier="ElasticPremium"
    fi
    
    if [[ -n "$downgrade_sku" ]]; then
        # SKU downgrade doubles utilization (half the resources)
        local proj_cpu_avg_sku=$(( cpu_avg * 2 ))
        local proj_cpu_max_sku=$(( cpu_max * 2 ))
        local proj_mem_avg_sku=$(( mem_avg * 2 ))
        local proj_mem_max_sku=$(( mem_max * 2 ))
        
        [[ $proj_cpu_avg_sku -gt 100 ]] && proj_cpu_avg_sku=100
        [[ $proj_cpu_max_sku -gt 100 ]] && proj_cpu_max_sku=100
        [[ $proj_mem_avg_sku -gt 100 ]] && proj_mem_avg_sku=100
        [[ $proj_mem_max_sku -gt 100 ]] && proj_mem_max_sku=100
        
        local risk_sku="MEDIUM"
        local confidence_sku=75
        
        # CRITICAL: Memory-aware risk assessment for SKU downgrades
        # If current memory is already high, downgrading is very dangerous
        if [[ $mem_max -gt 90 ]]; then
            risk_sku="HIGH"
            confidence_sku=30
        elif [[ $mem_max -gt 80 ]]; then
            risk_sku="HIGH"
            confidence_sku=40
        elif [[ $mem_max -gt 70 ]]; then
            risk_sku="MEDIUM"
            confidence_sku=60
        fi
        
        # Also check projected utilization
        [[ $proj_cpu_max_sku -gt 85 || $proj_mem_max_sku -gt 90 ]] && risk_sku="HIGH" && confidence_sku=45
        [[ $proj_cpu_max_sku -lt 70 && $proj_mem_max_sku -lt 70 && $mem_max -lt 70 ]] && risk_sku="LOW" && confidence_sku=85
        
        options+="SKU_DOWNGRADE|$downgrade_tier|$downgrade_sku|$current_capacity|Downgrade SKU tier (half resources per instance)|$risk_sku|$proj_cpu_avg_sku|$proj_cpu_max_sku|$proj_mem_avg_sku|$proj_mem_max_sku|$confidence_sku\n"
        
        # Combined: SKU downgrade + capacity reduction
        if [[ $current_capacity -gt 1 ]]; then
            local new_cap_combined=$(( (current_capacity + 1) / 2 ))
            local proj_cpu_avg_combined=$(( cpu_avg * 2 * current_capacity / new_cap_combined ))
            local proj_cpu_max_combined=$(( cpu_max * 2 * current_capacity / new_cap_combined ))
            local proj_mem_avg_combined=$(( mem_avg * 2 * current_capacity / new_cap_combined ))
            local proj_mem_max_combined=$(( mem_max * 2 * current_capacity / new_cap_combined ))
            
            [[ $proj_cpu_avg_combined -gt 100 ]] && proj_cpu_avg_combined=100
            [[ $proj_cpu_max_combined -gt 100 ]] && proj_cpu_max_combined=100
            [[ $proj_mem_avg_combined -gt 100 ]] && proj_mem_avg_combined=100
            [[ $proj_mem_max_combined -gt 100 ]] && proj_mem_max_combined=100
            
            local risk_combined="HIGH"
            local confidence_combined=60
            
            # Combined changes are inherently risky, especially with high memory
            if [[ $mem_max -gt 80 || $proj_mem_max_combined -gt 95 ]]; then
                risk_combined="HIGH"
                confidence_combined=35
            elif [[ $proj_cpu_max_combined -lt 80 && $proj_mem_max_combined -lt 85 ]]; then
                risk_combined="MEDIUM"
                confidence_combined=65
            fi
            
            options+="COMBINED|$downgrade_tier|$downgrade_sku|$new_cap_combined|Downgrade SKU + reduce capacity|$risk_combined|$proj_cpu_avg_combined|$proj_cpu_max_combined|$proj_mem_avg_combined|$proj_mem_max_combined|$confidence_combined\n"
        fi
    fi
    
    echo -e "$options"
}

# Select best recommendation based on optimization strategy
recommend_rightsizing() {
    local current_tier="$1"
    local current_name="$2"
    local current_capacity="$3"
    local app_count="$4"
    local running_apps="$5"
    local cpu_avg="$6"
    local cpu_max="$7"
    local mem_avg="$8"
    local mem_max="$9"
    
    # Generate all options
    local all_options=$(generate_optimization_options "$current_tier" "$current_name" "$current_capacity" "$app_count" "$running_apps" "$cpu_avg" "$cpu_max" "$mem_avg" "$mem_max")
    
    # Filter options based on strategy
    local recommended_tier="$current_tier"
    local recommended_name="$current_name"
    local recommended_capacity=$current_capacity
    local selected_option="CURRENT"
    
    case "$OPTIMIZATION_STRATEGY" in
        "aggressive")
            # Target: Max CPU 85-90%, Max Memory 90-95%, prioritize maximum savings
            # Accept MEDIUM/HIGH risk if projected max CPU < 90% AND Memory < 95%
            # Fields: $8=projected_cpu_max, $10=projected_mem_max
            local best_option=$(echo -e "$all_options" | grep -v "^CURRENT" | awk -F'|' '$8 <= 90 && $10 <= 95' | sort -t'|' -k8 -rn | head -1)
            ;;
        "conservative")
            # Target: Max CPU 60-70%, Max Memory 70-75%, only LOW risk options
            # Preserve significant headroom for traffic spikes
            # Fields: $6=risk_level, $8=projected_cpu_max, $10=projected_mem_max
            local best_option=$(echo -e "$all_options" | grep -v "^CURRENT" | awk -F'|' '$6 == "LOW" && $8 <= 70 && $10 <= 75' | sort -t'|' -k8 -rn | head -1)
            ;;
        *)
            # balanced (default)
            # Target: Max CPU 75-80%, Max Memory 85%, prefer LOW/MEDIUM risk
            # Balance between savings and safety, reject if memory would exceed 90%
            # Fields: $6=risk_level, $8=projected_cpu_max, $10=projected_mem_max
            local best_option=$(echo -e "$all_options" | grep -v "^CURRENT" | awk -F'|' '($6 == "LOW" || $6 == "MEDIUM") && $8 <= 85 && $10 <= 90' | sort -t'|' -k8 -rn | head -1)
            ;;
    esac
    
    if [[ -n "$best_option" ]]; then
        selected_option=$(echo "$best_option" | cut -d'|' -f1)
        recommended_tier=$(echo "$best_option" | cut -d'|' -f2)
        recommended_name=$(echo "$best_option" | cut -d'|' -f3)
        recommended_capacity=$(echo "$best_option" | cut -d'|' -f4)
    fi
    
    # Also return the selected option type for context
    echo "$recommended_tier|$recommended_name|$recommended_capacity|$selected_option"
}

# Analyze App Service Plan
analyze_app_service_plan() {
    local plan_name="$1"
    local plan_id="$2"
    local resource_group="$3"
    local subscription_id="$4"
    local sku_tier="$5"
    local sku_name="$6"
    local sku_capacity="$7"
    local location="$8"
    
    log "  📋 Plan Details:"
    log "     Resource Group: $resource_group"
    log "     SKU: $sku_tier $sku_name"
    log "     Capacity: $sku_capacity instance(s)"
    log "     Location: $location"
    log ""
    
    # Get apps deployed to this plan using az resource list
    local apps=$(get_apps_for_plan "$plan_id" "$subscription_id")
    local app_count=$(echo "$apps" | jq length)
    local running_apps=$(echo "$apps" | jq '[.[] | select(.state == "Running")] | length')
    local stopped_apps=$(echo "$apps" | jq '[.[] | select(.state != "Running")] | length')
    
    log "  📱 Apps on this plan: $app_count total"
    log "     ✓ Running: $running_apps"
    log "     ✗ Stopped: $stopped_apps"
    log ""
    
    # Get performance metrics for this plan
    local metrics=$(get_plan_metrics "$plan_id" "$subscription_id")
    IFS='|' read -r cpu_avg cpu_max mem_avg mem_max <<< "$metrics"
    
    log "  📊 Performance Metrics (7 days):"
    log "     CPU: avg=${cpu_avg}%, max=${cpu_max}%"
    log "     Memory: avg=${mem_avg}%, max=${mem_max}%"
    log ""
    
    # Debug: if we see metrics but found 0 apps, show a warning but continue analysis
    if [[ $app_count -eq 0 ]] && [[ ${cpu_max} -gt 0 || ${mem_max} -gt 0 ]]; then
        log "  ⚠️  Note: Found metrics but 0 apps - the plan may have Function Apps in scale-to-zero mode"
        log ""
    fi
    
    if [[ $app_count -eq 0 ]]; then
        # Truly empty App Service Plan (no apps AND no metrics)
        local monthly_cost=$(calculate_plan_cost "$sku_tier" "$sku_name" "$sku_capacity")
        local annual_cost=$((monthly_cost * 12))
        
        log "🔸 Empty App Service Plan \`$plan_name\` - \$$monthly_cost/month waste"
        
        local issue=$(jq -n \
            --arg title "Empty App Service Plan \`$plan_name\`" \
            --arg description "This App Service Plan has no apps deployed" \
            --arg severity "2" \
            --arg monthly_cost "$monthly_cost" \
            --arg annual_cost "$annual_cost" \
            --arg plan_name "$plan_name" \
            --arg resource_group "$resource_group" \
            --arg subscription_id "$subscription_id" \
            --arg current_sku "$sku_tier $sku_name" \
            --arg current_capacity "$sku_capacity" \
            --arg location "$location" \
            '{
                title: $title,
                description: $description,
                severity: ($severity | tonumber),
                monthlyCost: ($monthly_cost | tonumber),
                annualCost: ($annual_cost | tonumber),
                planName: $plan_name,
                resourceGroup: $resource_group,
                subscriptionId: $subscription_id,
                currentSku: $current_sku,
                currentCapacity: ($current_capacity | tonumber),
                location: $location,
                type: "empty_plan"
            }')
        
        # Append to details file (not individual issues)
        if [[ -f "$DETAILS_FILE" ]]; then
            local existing_issues=$(cat "$DETAILS_FILE")
            echo "$existing_issues" | jq ". += [$issue]" > "$DETAILS_FILE"
        else
            echo "[$issue]" > "$DETAILS_FILE"
        fi
        
    else
        # Generate all optimization options with full analysis
        local all_options=$(generate_optimization_options "$sku_tier" "$sku_name" "$sku_capacity" "$app_count" "$running_apps" "$cpu_avg" "$cpu_max" "$mem_avg" "$mem_max")
        
        # Get recommended option based on strategy
        local rightsizing=$(recommend_rightsizing "$sku_tier" "$sku_name" "$sku_capacity" "$app_count" "$running_apps" "$cpu_avg" "$cpu_max" "$mem_avg" "$mem_max")
        IFS='|' read -r rec_tier rec_name rec_capacity selected_option <<< "$rightsizing"
        
        local current_cost=$(calculate_plan_cost "$sku_tier" "$sku_name" "$sku_capacity")
        local recommended_cost=$(calculate_plan_cost "$rec_tier" "$rec_name" "$rec_capacity")
        
        # Build options table for display - Cleaner format
        log "  📊 OPTIMIZATION OPTIONS:"
        log ""
        
        # Format and display all options
        local options_json="[]"
        local option_num=1
        while IFS='|' read -r opt_id opt_tier opt_name opt_capacity opt_desc opt_risk opt_cpu_avg opt_cpu_max opt_mem_avg opt_mem_max opt_confidence; do
            [[ -z "$opt_id" ]] && continue
            
            local opt_cost=$(calculate_plan_cost "$opt_tier" "$opt_name" "$opt_capacity")
            local opt_savings=$((current_cost - opt_cost))
            
            # Color-code risk
            local risk_icon=""
            case "$opt_risk" in
                "HIGH") risk_icon="🔴" ;;
                "MEDIUM") risk_icon="🟡" ;;
                "LOW") risk_icon="🟢" ;;
                "NONE") risk_icon="⚪" ;;
            esac
            
            # Mark selected option
            local selected_marker=""
            [[ "$opt_id" == "$selected_option" ]] && selected_marker=" ⭐ RECOMMENDED"
            
            # Show option in clean block format
            if [[ "$opt_id" == "CURRENT" ]]; then
                log "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log "  ${risk_icon} OPTION ${option_num}: Keep Current Configuration${selected_marker}"
                log "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            else
                log "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log "  ${risk_icon} OPTION ${option_num}: ${opt_desc}${selected_marker}"
                log "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            fi
            
            log "     Configuration:    $opt_name x${opt_capacity} instance(s)"
            log "     Projected CPU:    Avg ${opt_cpu_avg}%, Max ${opt_cpu_max}%"
            log "     Projected Memory: Avg ${opt_mem_avg}%, Max ${opt_mem_max}%"
            log "     Risk Level:       ${opt_risk} (Confidence: ${opt_confidence}%)"
            log "     Monthly Cost:     \$${opt_cost}"
            
            if [[ $opt_savings -gt 0 ]]; then
                local savings_pct=$(( (opt_savings * 100) / current_cost ))
                log "     Monthly Savings:  \$${opt_savings} (${savings_pct}% reduction)"
                log "     Annual Savings:   \$$(( opt_savings * 12 ))"
            fi
            log ""
            
            option_num=$((option_num + 1))
            
            # Build JSON for storage
            local opt_json=$(jq -n \
                --arg option_id "$opt_id" \
                --arg description "$opt_desc" \
                --arg tier "$opt_tier" \
                --arg name "$opt_name" \
                --arg capacity "$opt_capacity" \
                --arg risk "$opt_risk" \
                --arg cpu_avg "$opt_cpu_avg" \
                --arg cpu_max "$opt_cpu_max" \
                --arg mem_avg "$opt_mem_avg" \
                --arg mem_max "$opt_mem_max" \
                --arg confidence "$opt_confidence" \
                --arg monthly_cost "$opt_cost" \
                --arg savings "$opt_savings" \
                '{
                    optionId: $option_id,
                    description: $description,
                    tier: $tier,
                    name: $name,
                    capacity: ($capacity | tonumber),
                    risk: $risk,
                    projectedCpuAvg: ($cpu_avg | tonumber),
                    projectedCpuMax: ($cpu_max | tonumber),
                    projectedMemAvg: ($mem_avg | tonumber),
                    projectedMemMax: ($mem_max | tonumber),
                    confidence: ($confidence | tonumber),
                    monthlyCost: ($monthly_cost | tonumber),
                    monthlySavings: ($savings | tonumber)
                }')
            options_json=$(echo "$options_json" | jq ". += [$opt_json]")
            
        done <<< "$all_options"
        
        log "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "  Legend: 🔴 High Risk  🟡 Medium Risk  🟢 Low Risk  ⚪ No Change"
        log "  ⭐ = Recommended for '$OPTIMIZATION_STRATEGY' strategy"
        log ""
        
        if [[ $recommended_cost -lt $current_cost ]]; then
            local monthly_savings=$((current_cost - recommended_cost))
            local annual_savings=$((monthly_savings * 12))
            
            log "💡 Rightsizing opportunity: \`$plan_name\` - \$$monthly_savings/month savings ($OPTIMIZATION_STRATEGY strategy)"
            log "  Current: $sku_tier $sku_name x$sku_capacity (\$$current_cost/month)"
            log "  Recommended: $rec_tier $rec_name x$rec_capacity (\$$recommended_cost/month)"
            log ""
            log "  📝 Context & Rationale:"
            log "     • Current utilization is below optimal levels"
            log "     • 7-day metrics show consistent underutilization pattern"
            log "     • $running_apps/$app_count apps are currently running"
            log "     • Selected option balances cost savings with operational safety"
            log ""
            log "  ⚡ Implementation Risk Assessment:"
            # Get selected option details
            local selected_risk=$(echo -e "$all_options" | grep "^$selected_option" | cut -d'|' -f6)
            local selected_conf=$(echo -e "$all_options" | grep "^$selected_option" | cut -d'|' -f11)
            local selected_proj_mem_max=$(echo -e "$all_options" | grep "^$selected_option" | cut -d'|' -f10)
            
            # Add memory-specific warnings for high memory scenarios
            if [[ $mem_max -gt 90 && "$selected_option" == *"DOWNGRADE"* ]]; then
                log "     🚨 CRITICAL MEMORY WARNING:"
                log "     • Current memory utilization is VERY HIGH ($mem_max% max)"
                log "     • SKU downgrade will halve available memory"
                log "     • This creates HIGH RISK of out-of-memory errors"
                log "     • Strongly consider capacity reduction instead of SKU downgrade"
                log "     • Or investigate application memory optimization first"
                log ""
            elif [[ $mem_max -gt 80 && "$selected_option" == *"DOWNGRADE"* ]]; then
                log "     ⚠️  MEMORY PRESSURE WARNING:"
                log "     • Current memory utilization is elevated ($mem_max% max)"
                log "     • SKU downgrade will reduce available memory significantly"
                log "     • Monitor memory closely after implementation"
                log "     • Consider alternative options if memory spikes are common"
                log ""
            fi
            
            case "$selected_risk" in
                "LOW")
                    log "     ✅ LOW RISK - Safe to implement with minimal performance impact"
                    log "     • Projected utilization stays well within safe thresholds"
                    log "     • Ample headroom for traffic spikes and growth"
                    ;;
                "MEDIUM")
                    log "     ⚠️  MEDIUM RISK - Monitor performance after implementation"
                    log "     • Projected utilization approaches recommended thresholds"
                    log "     • Consider implementing during low-traffic period"
                    log "     • Have rollback plan ready"
                    if [[ $selected_proj_mem_max -gt 85 ]]; then
                        log "     • NOTICE: Projected memory max is ${selected_proj_mem_max}% - monitor memory usage closely"
                    fi
                    ;;
                "HIGH")
                    log "     🔴 HIGH RISK - Careful evaluation recommended"
                    log "     • Projected utilization near capacity limits"
                    log "     • Implement with caution and extensive monitoring"
                    log "     • Consider gradual rollout or alternative options"
                    if [[ $selected_proj_mem_max -ge 95 ]]; then
                        log "     • CRITICAL: Projected memory at ${selected_proj_mem_max}% - review alternative options"
                    fi
                    ;;
            esac
            log "     • Recommendation confidence: ${selected_conf}%"
            log ""
            
            local issue=$(jq -n \
                --arg title "Rightsize App Service Plan \`$plan_name\` ($OPTIMIZATION_STRATEGY)" \
                --arg description "This App Service Plan can be optimized based on 7-day metrics analysis.\n\nCurrent Performance:\n• CPU: ${cpu_avg}% avg, ${cpu_max}% max\n• Memory: ${mem_avg}% avg, ${mem_max}% max\n• Apps: ${running_apps}/${app_count} running\n\nOptimization Strategy: $OPTIMIZATION_STRATEGY\nSelected Option: $selected_option (Risk: $selected_risk, Confidence: ${selected_conf}%)\n\nSee detailed options table in report for all alternatives." \
                --arg severity "3" \
                --arg monthly_cost "$monthly_savings" \
                --arg annual_cost "$annual_savings" \
                --arg current_monthly_cost "$current_cost" \
                --arg recommended_monthly_cost "$recommended_cost" \
                --arg plan_name "$plan_name" \
                --arg resource_group "$resource_group" \
                --arg subscription_id "$subscription_id" \
                --arg current_sku "$sku_tier $sku_name" \
                --arg current_capacity "$sku_capacity" \
                --arg recommended_sku "$rec_tier $rec_name" \
                --arg recommended_capacity "$rec_capacity" \
                --arg app_count "$app_count" \
                --arg running_apps "$running_apps" \
                --arg cpu_avg "$cpu_avg" \
                --arg cpu_max "$cpu_max" \
                --arg mem_avg "$mem_avg" \
                --arg mem_max "$mem_max" \
                --arg location "$location" \
                --arg strategy "$OPTIMIZATION_STRATEGY" \
                --arg selected_option "$selected_option" \
                --argjson options_table "$options_json" \
                '{
                    title: $title,
                    description: $description,
                    severity: ($severity | tonumber),
                    monthlyCost: ($monthly_cost | tonumber),
                    annualCost: ($annual_cost | tonumber),
                    currentMonthlyCost: ($current_monthly_cost | tonumber),
                    recommendedMonthlyCost: ($recommended_monthly_cost | tonumber),
                    planName: $plan_name,
                    resourceGroup: $resource_group,
                    subscriptionId: $subscription_id,
                    currentSku: $current_sku,
                    currentCapacity: ($current_capacity | tonumber),
                    recommendedSku: $recommended_sku,
                    recommendedCapacity: ($recommended_capacity | tonumber),
                    appCount: ($app_count | tonumber),
                    runningApps: ($running_apps | tonumber),
                    cpuAvg: ($cpu_avg | tonumber),
                    cpuMax: ($cpu_max | tonumber),
                    memAvg: ($mem_avg | tonumber),
                    memMax: ($mem_max | tonumber),
                    location: $location,
                    strategy: $strategy,
                    selectedOption: $selected_option,
                    allOptions: $options_table,
                    type: "rightsizing"
                }')
            
            # Append to details file (not individual issues)
            if [[ -f "$DETAILS_FILE" ]]; then
                local existing_issues=$(cat "$DETAILS_FILE")
                echo "$existing_issues" | jq ". += [$issue]" > "$DETAILS_FILE"
            else
                echo "[$issue]" > "$DETAILS_FILE"
            fi
        else
            log "  ✅ App Service Plan is appropriately sized for current workload"
            log "     No optimization opportunities found with $OPTIMIZATION_STRATEGY strategy"
        fi
    fi
    
    log ""
}

# Main function
main() {
    # Initialize performance utilities
    azure_perf_init "." 2>/dev/null || true
    
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   Azure App Service Cost Optimization Analysis                   ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Show scan mode and Resource Graph status
    print_scan_mode_info 2>/dev/null || true
    
    log "🚀 Starting analysis at $(date '+%Y-%m-%d %H:%M:%S')"
    log ""
    log "⚙️  Optimization Strategy: $OPTIMIZATION_STRATEGY"
    case "$OPTIMIZATION_STRATEGY" in
        "aggressive")
            log "   → Target: Maximum cost savings (85-90% max CPU utilization)"
            log "   → Risk tolerance: Medium to High"
            log "   → Best for: Non-critical workloads, test/dev environments"
            ;;
        "conservative")
            log "   → Target: Safe optimizations (60-70% max CPU utilization)"
            log "   → Risk tolerance: Low only"
            log "   → Best for: Production workloads, traffic growth expected"
            ;;
        *)
            log "   → Target: Balanced savings and safety (75-80% max CPU utilization)"
            log "   → Risk tolerance: Low to Medium"
            log "   → Best for: Most production workloads"
            ;;
    esac
    log ""
    
    if [[ -z "$SUBSCRIPTION_IDS" ]]; then
        echo "❌ Error: AZURE_SUBSCRIPTION_IDS environment variable not set"
        exit 1
    fi
    
    # This script currently processes one subscription at a time
    # Take the first subscription from comma-separated list
    local SUBSCRIPTION_ID=$(echo "$SUBSCRIPTION_IDS" | cut -d',' -f1 | xargs)
    log "🎯 Target subscription: $SUBSCRIPTION_ID"
    log ""
    
    # If RESOURCE_GROUPS is empty, get all resource groups in the subscription
    if [[ -z "$RESOURCE_GROUPS" ]]; then
        log "🔍 No resource groups specified - discovering all resource groups..."
        RESOURCE_GROUPS=$(az group list --subscription "$SUBSCRIPTION_ID" --query "[].name" -o tsv 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        
        if [[ -z "$RESOURCE_GROUPS" ]]; then
            echo "❌ Error: No resource groups found in subscription $SUBSCRIPTION_ID"
            exit 1
        fi
        
        local rg_count=$(echo "$RESOURCE_GROUPS" | tr ',' '\n' | wc -l)
        log "✓ Found $rg_count resource groups"
    else
        local rg_count=$(echo "$RESOURCE_GROUPS" | tr ',' '\n' | wc -l)
        log "🎯 Analyzing $rg_count specified resource group(s)"
    fi
    log ""
    
    # Initialize output files
    log "Initializing output files in directory: $(pwd)"
    if echo "[]" > "$DETAILS_FILE" 2>&1; then
        log "✓ Details file created: $DETAILS_FILE"
    else
        echo "❌ FATAL: Cannot write to $DETAILS_FILE in directory $(pwd)" >&2
        echo "   Check directory permissions and disk space" >&2
        exit 1
    fi
    echo "[]" > "$ISSUES_FILE"  # Grouped issues will be created at the end
    
    # Process each resource group
    IFS=',' read -ra RG_ARRAY <<< "$RESOURCE_GROUPS"
    
    # Filter out empty strings from array (trim and check)
    local FILTERED_RG_ARRAY=()
    for rg in "${RG_ARRAY[@]}"; do
        rg=$(echo "$rg" | xargs)  # trim whitespace
        if [[ -n "$rg" ]]; then
            FILTERED_RG_ARRAY+=("$rg")
        fi
    done
    
    local total_rgs=${#FILTERED_RG_ARRAY[@]}
    
    # Check if we have any resource groups to process
    if [[ $total_rgs -eq 0 ]]; then
        log "⚠️  No valid resource groups specified. Please set AZURE_RESOURCE_GROUPS environment variable."
        log "   Example: export AZURE_RESOURCE_GROUPS='rg1,rg2,rg3'"
        log ""
        # Create empty output files
        echo '[]' > "$DETAILS_FILE"
        echo '[]' > "$ISSUES_FILE"
        return 1
    fi
    
    local current_rg=0
    local failed_rgs=0
    local processed_rgs=0
    
    for rg in "${FILTERED_RG_ARRAY[@]}"; do
        current_rg=$((current_rg + 1))  # Increment safely (set -e compatible)
        
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        log "📦 Analyzing resource group [$current_rg/$total_rgs]: $rg"
        log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Get all App Service Plans in this resource group (use Resource Graph if available)
        log "  Querying App Service Plans..."
        local plans
        
        if is_resource_graph_available 2>/dev/null; then
            # Use Resource Graph for faster query
            local graph_result=$(query_appservice_plans_graph "$SUBSCRIPTION_ID")
            plans=$(echo "$graph_result" | jq --arg rg "$rg" '[.data[] | select(.resourceGroup == $rg) | {
                name: .name,
                id: .id,
                resourceGroup: .resourceGroup,
                sku: {name: .skuName, tier: .skuTier, capacity: .skuCapacity},
                location: .location
            }]')
        elif ! plans=$(az appservice plan list --resource-group "$rg" --subscription "$SUBSCRIPTION_ID" \
            --query "[].{name:name, id:id, resourceGroup:resourceGroup, sku:sku, location:location}" \
            -o json 2>&1); then
            log "  ⚠️  Failed to query resource group $rg: $plans"
            failed_rgs=$((failed_rgs + 1))
            log ""
            continue
        fi
        
        # Ensure we have valid JSON
        if ! echo "$plans" | jq empty 2>/dev/null; then
            log "  ⚠️  Invalid JSON response from resource group $rg"
            failed_rgs=$((failed_rgs + 1))
            log ""
            continue
        fi
        
        local plan_count=$(echo "$plans" | jq 'length' 2>/dev/null || echo "0")
        log "  ✓ Found $plan_count App Service Plan(s) in resource group: $rg"
        processed_rgs=$((processed_rgs + 1))
        
        if [[ $plan_count -gt 0 ]]; then
            local plan_num=0
            echo "$plans" | jq -c '.[]' | while read -r plan; do
                plan_num=$((plan_num + 1))
                local plan_name=$(echo "$plan" | jq -r '.name')
                local plan_id=$(echo "$plan" | jq -r '.id')
                local resource_group=$(echo "$plan" | jq -r '.resourceGroup')
                local sku_tier=$(echo "$plan" | jq -r '.sku.tier')
                local sku_name=$(echo "$plan" | jq -r '.sku.name')
                local sku_capacity=$(echo "$plan" | jq -r '.sku.capacity')
                local location=$(echo "$plan" | jq -r '.location')
                
                log ""
                log "  ┌─────────────────────────────────────────────────────────────"
                log "  │ App Service Plan [$plan_num/$plan_count]: $plan_name"
                log "  └─────────────────────────────────────────────────────────────"
                
                # Analyze with error handling
                if ! analyze_app_service_plan "$plan_name" "$plan_id" "$resource_group" "$SUBSCRIPTION_ID" \
                    "$sku_tier" "$sku_name" "$sku_capacity" "$location" 2>&1; then
                    log "  ⚠️  Failed to analyze plan $plan_name - continuing..."
                fi
            done
        else
            log "  ℹ️  No App Service Plans in this resource group - skipping"
        fi
    done
    
    # Generate summary from details
    local total_monthly=$(jq '[.[].monthlyCost] | add // 0' "$DETAILS_FILE")
    local total_annual=$(jq '[.[].annualCost] | add // 0' "$DETAILS_FILE")
    local total_current_spend=$(jq '[.[].currentMonthlyCost] | add // 0' "$DETAILS_FILE")
    local total_recommended_spend=$(jq '[.[].recommendedMonthlyCost] | add // 0' "$DETAILS_FILE")
    local detail_count=$(jq 'length' "$DETAILS_FILE")
    
    # Create grouped issues by financial impact
    log "Creating grouped issues by financial impact..."
    create_grouped_issues
    
    # Calculate savings percentage
    local savings_percentage=0
    if [[ $total_current_spend -gt 0 ]]; then
        savings_percentage=$(awk "BEGIN {printf \"%.1f\", ($total_monthly / $total_current_spend) * 100}")
    fi
    
    echo ""
    log "══════════════════════════════════════════════════════════════════"
    log "✅ Analysis completed at $(date '+%Y-%m-%d %H:%M:%S')"
    log "══════════════════════════════════════════════════════════════════"
    log ""
    log "📊 RESOURCE GROUPS PROCESSED:"
    log "   Total resource groups: $total_rgs"
    log "   Successfully processed: $processed_rgs"
    if [[ $failed_rgs -gt 0 ]]; then
        log "   ⚠️  Failed: $failed_rgs"
    fi
    log ""
    log "💰 COST SUMMARY:"
    log "   Current monthly spend: \$$total_current_spend (for plans with issues)"
    log "   Potential monthly savings: \$$total_monthly ($savings_percentage% reduction)"
    log "   Potential annual savings: \$$total_annual"
    log "   Optimization opportunities: $detail_count"
    log ""
    
    local grouped_issue_count=$(jq 'length' "$ISSUES_FILE")
    log "📋 Created $grouped_issue_count grouped issue(s) by financial impact"
    log ""
    
    # Generate report
    cat > "$REPORT_FILE" << EOF
╔═══════════════════════════════════════════════════════════════════╗
║   AZURE APP SERVICE COST OPTIMIZATION REPORT                      ║
╚═══════════════════════════════════════════════════════════════════╝

📊 ANALYSIS CONFIGURATION:
━━━━━━━━━━━━━━━━━━━━━━━━━━━
• Optimization Strategy: $OPTIMIZATION_STRATEGY
• Analysis Period: 7 days of Azure Monitor metrics
• Date: $(date '+%Y-%m-%d %H:%M:%S')

STRATEGY DETAILS:
$(case "$OPTIMIZATION_STRATEGY" in
    "aggressive")
        echo "  → Maximum cost savings approach (85-90% max CPU target)"
        echo "  → Accepts Medium-High risk for greater savings"
        echo "  → Best for: Non-production, test/dev environments"
        ;;
    "conservative")
        echo "  → Safe optimization approach (60-70% max CPU target)"
        echo "  → Only Low-risk recommendations"
        echo "  → Best for: Critical production workloads"
        ;;
    *)
        echo "  → Balanced approach (75-80% max CPU target)"
        echo "  → Low-Medium risk recommendations"
        echo "  → Best for: Standard production workloads"
        ;;
esac)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🎯 COST SAVINGS SUMMARY:
━━━━━━━━━━━━━━━━━━━━━━━━━━━
💵 Current Monthly Spend:    \$$total_current_spend (for resources with issues)
💰 Potential Monthly Savings: \$$total_monthly ($savings_percentage% reduction)
💰 Potential Annual Savings:  \$$total_annual
📉 Recommended Monthly Spend: \$$total_recommended_spend
📊 Optimization Opportunities: $detail_count

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🔥 TOP SAVINGS OPPORTUNITIES:
$(jq -r 'sort_by(-.monthlyCost) | .[:5] | .[] | "   • " + .planName + " - $" + (.monthlyCost | tostring) + "/month (" + ((.monthlyCost / .currentMonthlyCost * 100) | floor | tostring) + "% savings)\n     Current: " + .currentSku + " x" + (.currentCapacity | tostring) + " | CPU: " + (.cpuAvg | tostring) + "% avg, " + (.cpuMax | tostring) + "% max\n     Strategy: " + .selectedOption + "\n"' "$DETAILS_FILE")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

⚡ DETAILED RIGHTSIZING RECOMMENDATIONS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(jq -r '.[] | select(.type == "rightsizing") | 
"
┌─────────────────────────────────────────────────────────────────
│ App Service Plan: " + .planName + "
│ Resource Group: " + .resourceGroup + "
├─────────────────────────────────────────────────────────────────
│ CURRENT CONFIGURATION:
│   • SKU: " + .currentSku + " x" + (.currentCapacity | tostring) + " instances
│   • Monthly Cost: $" + (.currentMonthlyCost | tostring) + "
│   • Apps: " + (.runningApps | tostring) + "/" + (.appCount | tostring) + " running
│   • Utilization (7-day):
│     - CPU: " + (.cpuAvg | tostring) + "% avg, " + (.cpuMax | tostring) + "% max
│     - Memory: " + (.memAvg | tostring) + "% avg, " + (.memMax | tostring) + "% max
│
│ RECOMMENDED CONFIGURATION (" + .strategy + " strategy):
│   • SKU: " + .recommendedSku + " x" + (.recommendedCapacity | tostring) + " instances
│   • Monthly Cost: $" + (.recommendedMonthlyCost | tostring) + "
│   • Monthly Savings: $" + (.monthlyCost | tostring) + " (" + ((.monthlyCost / .currentMonthlyCost * 100) | floor | tostring) + "%)
│   • Annual Savings: $" + (.annualCost | tostring) + "
│   • Selected Option: " + .selectedOption + "
│
│ ALL AVAILABLE OPTIONS:
" + (.allOptions | map("│   " + (.description | .[0:45] + (if (. | length) > 45 then "..." else "" end)) + " | " + .name + " x" + (.capacity | tostring) + " | CPU: " + (.projectedCpuMax | tostring) + "% max | Risk: " + .risk + " | $" + (.monthlyCost | tostring) + "/mo | Savings: $" + (.monthlySavings | tostring)) | join("\n")) + "
│
│ IMPLEMENTATION COMMAND:
│   az appservice plan update \\
│     --name '\''" + .planName + "'\'' \\
│     --resource-group '\''" + .resourceGroup + "'\'' \\
│     --subscription '\''" + .subscriptionId + "'\'' \\
│     --sku " + (.recommendedSku | split(" ")[1]) + " \\
│     --number-of-workers " + (.recommendedCapacity | tostring) + "
└─────────────────────────────────────────────────────────────────
"' "$DETAILS_FILE")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🗑️  EMPTY APP SERVICE PLANS (Cleanup Opportunities):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
$(jq -r '.[] | select(.type == "empty_plan") | 
"Plan: " + .planName + " (" + .resourceGroup + ")
  • Current Cost: $" + (.monthlyCost | tostring) + "/month waste
  • No apps deployed
  • Delete Command:
    az appservice plan delete --name '\''" + .planName + "'\'' --resource-group '\''" + .resourceGroup + "'\'' --subscription '\''" + .subscriptionId + "'\'' --yes
"' "$DETAILS_FILE")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📝 NOTES & RECOMMENDATIONS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Review the "ALL AVAILABLE OPTIONS" table for each plan to understand 
   alternative optimization strategies.

2. Risk Assessment:
   • LOW: Safe to implement, minimal performance impact
   • MEDIUM: Monitor closely after implementation, implement during low-traffic
   • HIGH: Requires careful evaluation, consider gradual rollout

3. To change optimization strategy, set OPTIMIZATION_STRATEGY environment variable:
   • aggressive: Maximum savings (use for dev/test)
   • balanced: Default, balances cost and safety
   • conservative: Minimal risk (use for critical production)

4. Always test changes in non-production environments first.

5. Monitor performance for 24-48 hours after any changes.

6. Consider traffic patterns and growth projections when selecting options.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

💡 Need different recommendations? Run with:
   export OPTIMIZATION_STRATEGY=conservative  # or aggressive
   ./azure_appservice_cost_optimization.sh

📊 For complete JSON data with all options, see:
   azure_appservice_cost_optimization_details.json

EOF
    
    cat "$REPORT_FILE"
}

# Create grouped issues by financial impact level
create_grouped_issues() {
    local high_impact=$(jq "[.[] | select(.monthlyCost >= $HIGH_COST_THRESHOLD)]" "$DETAILS_FILE")
    local medium_impact=$(jq "[.[] | select(.monthlyCost >= $MEDIUM_COST_THRESHOLD and .monthlyCost < $HIGH_COST_THRESHOLD)]" "$DETAILS_FILE")
    local low_impact=$(jq "[.[] | select(.monthlyCost < $MEDIUM_COST_THRESHOLD)]" "$DETAILS_FILE")
    
    local high_count=$(echo "$high_impact" | jq 'length')
    local medium_count=$(echo "$medium_impact" | jq 'length')
    local low_count=$(echo "$low_impact" | jq 'length')
    
    local issues="[]"
    
    # Create HIGH savings issue if there are any
    if [[ $high_count -gt 0 ]]; then
        local high_total=$(echo "$high_impact" | jq '[.[].monthlyCost] | add')
        local high_annual=$(echo "$high_impact" | jq '[.[].annualCost] | add')
        local high_plans=$(echo "$high_impact" | jq -r '[.[].planName] | join(", ")')
        local high_details=$(echo "$high_impact" | jq -r '.[] | "• " + .planName + " (" + .resourceGroup + "): $" + (.monthlyCost | tostring) + "/month savings - Risk: " + .riskLevel + "\n  Current: " + .currentSku + " x" + (.currentCapacity | tostring) + " | " + (if .type == "empty_plan" then "EMPTY (no apps)" else "CPU: " + (.cpuAvg | tostring) + "% avg, " + (.cpuMax | tostring) + "% max" end)' | head -20)
        
        local high_issue=$(jq -n \
            --arg title "HIGH Savings: App Service Cost Optimization ($high_count plans, \$$high_total/month potential savings)" \
            --arg details "Found $high_count App Service Plans with HIGH potential savings (≥\$$HIGH_COST_THRESHOLD/month each).\n\n💰 Total Potential Savings: \$$high_total/month (\$$high_annual/year)\n\n⚠️ NOTE: Review implementation risk for each recommendation before proceeding.\n\nAffected Plans (with risk assessment):\n$high_details" \
            --arg next_step "Review the detailed report in azure_appservice_cost_optimization_details.json. Prioritize LOW-risk recommendations first. For empty plans, delete them if no longer needed. For underutilized plans, consider rightsizing to smaller SKUs or consolidating apps onto fewer plans. For rightsizing commands, check the RIGHTSIZING RECOMMENDATIONS section in the analysis output." \
            --argjson severity 2 \
            '{
                title: $title,
                details: $details,
                next_step: $next_step,
                severity: $severity
            }')
        issues=$(echo "$issues" | jq ". += [$high_issue]")
    fi
    
    # Create MEDIUM savings issue if there are any
    if [[ $medium_count -gt 0 ]]; then
        local medium_total=$(echo "$medium_impact" | jq '[.[].monthlyCost] | add')
        local medium_annual=$(echo "$medium_impact" | jq '[.[].annualCost] | add')
        local medium_plans=$(echo "$medium_impact" | jq -r '[.[].planName] | join(", ")')
        local medium_details=$(echo "$medium_impact" | jq -r '.[] | "• " + .planName + " (" + .resourceGroup + "): $" + (.monthlyCost | tostring) + "/month savings - Risk: " + .riskLevel + "\n  Current: " + .currentSku + " x" + (.currentCapacity | tostring) + " | " + (if .type == "empty_plan" then "EMPTY (no apps)" else "CPU: " + (.cpuAvg | tostring) + "% avg, " + (.cpuMax | tostring) + "% max" end)' | head -20)
        
        local medium_issue=$(jq -n \
            --arg title "MEDIUM Savings: App Service Cost Optimization ($medium_count plans, \$$medium_total/month potential savings)" \
            --arg details "Found $medium_count App Service Plans with MEDIUM potential savings (\$$MEDIUM_COST_THRESHOLD-\$$HIGH_COST_THRESHOLD/month each).\n\n💰 Total Potential Savings: \$$medium_total/month (\$$medium_annual/year)\n\n⚠️ NOTE: Review implementation risk for each recommendation before proceeding.\n\nAffected Plans (with risk assessment):\n$medium_details" \
            --arg next_step "Review the detailed report in azure_appservice_cost_optimization_details.json. Prioritize LOW-risk recommendations first. Consider consolidating apps or rightsizing these plans to optimize costs. For specific commands, check the analysis output." \
            --argjson severity 3 \
            '{
                title: $title,
                details: $details,
                next_step: $next_step,
                severity: $severity
            }')
        issues=$(echo "$issues" | jq ". += [$medium_issue]")
    fi
    
    # Create LOW savings issue if there are any
    if [[ $low_count -gt 0 ]]; then
        local low_total=$(echo "$low_impact" | jq '[.[].monthlyCost] | add')
        local low_annual=$(echo "$low_impact" | jq '[.[].annualCost] | add')
        local low_plans=$(echo "$low_impact" | jq -r '[.[].planName] | join(", ")')
        local low_details=$(echo "$low_impact" | jq -r '.[] | "• " + .planName + " (" + .resourceGroup + "): $" + (.monthlyCost | tostring) + "/month savings - Risk: " + .riskLevel + "\n  Current: " + .currentSku + " x" + (.currentCapacity | tostring) + " | " + (if .type == "empty_plan" then "EMPTY (no apps)" else "CPU: " + (.cpuAvg | tostring) + "% avg, " + (.cpuMax | tostring) + "% max" end)' | head -20)
        
        local low_issue=$(jq -n \
            --arg title "LOW Savings: App Service Cost Optimization ($low_count plans, \$$low_total/month potential savings)" \
            --arg details "Found $low_count App Service Plans with LOW potential savings (<\$$MEDIUM_COST_THRESHOLD/month each).\n\n💰 Total Potential Savings: \$$low_total/month (\$$low_annual/year)\n\n✅ TIP: Focus on LOW-risk recommendations first - they're safer to implement and still add up!\n\nAffected Plans (with risk assessment):\n$low_details" \
            --arg next_step "These are lower-priority optimizations based on savings amount, but LOW-risk recommendations can be implemented safely. Review the detailed report in azure_appservice_cost_optimization_details.json. Consider addressing LOW-risk items first, then tackle MEDIUM-risk during regular maintenance windows." \
            --argjson severity 4 \
            '{
                title: $title,
                details: $details,
                next_step: $next_step,
                severity: $severity
            }')
        issues=$(echo "$issues" | jq ". += [$low_issue]")
    fi
    
    # Write grouped issues to file
    echo "$issues" > "$ISSUES_FILE"
    
    log "✓ Created grouped issues: HIGH=$high_count, MEDIUM=$medium_count, LOW=$low_count"
}

main "$@"
