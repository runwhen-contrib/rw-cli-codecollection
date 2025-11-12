#!/bin/bash

# Azure AKS Node Pool Optimization Analysis Script
# Analyzes AKS cluster node pools and provides resizing recommendations based on actual utilization
# Looks at peak CPU/memory over the past 30 days to propose node count reductions or different VM types

set -euo pipefail

# Environment variables expected:
# AZURE_SUBSCRIPTION_IDS - Comma-separated list of subscription IDs to analyze (required)
# AZURE_RESOURCE_GROUPS - Comma-separated list of resource groups to analyze (optional, defaults to all)
# AZURE_SUBSCRIPTION_ID - Single subscription ID (for backward compatibility)
# COST_ANALYSIS_LOOKBACK_DAYS - Days to look back for metrics (default: 30)
# AZURE_DISCOUNT_PERCENTAGE - Discount percentage off MSRP (optional, defaults to 0)

# Configuration
LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS:-30}
REPORT_FILE="aks_node_pool_optimization_report.txt"
ISSUES_FILE="aks_node_pool_optimization_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/aks_node_pool_optimization_issues_$$.json"

# Cost thresholds for severity classification
LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD:-500}
MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD:-2000}
HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD:-10000}

# Discount percentage (default to 0 if not set)
DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE:-0}

# Utilization thresholds for recommendations
CPU_UNDERUTILIZATION_THRESHOLD=40    # If peak CPU < 40%, consider downsizing
MEMORY_UNDERUTILIZATION_THRESHOLD=50 # If peak memory < 50%, consider downsizing
CPU_OPTIMIZATION_THRESHOLD=60        # If peak CPU < 60%, strong recommendation
MEMORY_OPTIMIZATION_THRESHOLD=65     # If peak memory < 65%, strong recommendation

# Safety margins for capacity planning (configurable)
MIN_NODE_SAFETY_MARGIN_PERCENT=${MIN_NODE_SAFETY_MARGIN_PERCENT:-150}  # 150% = 1.5x safety buffer for min nodes (based on average utilization)
MAX_NODE_SAFETY_MARGIN_PERCENT=${MAX_NODE_SAFETY_MARGIN_PERCENT:-150}  # 150% = 1.5x safety buffer for max nodes (based on peak utilization)
TARGET_UTILIZATION_PERCENT=80  # Target 80% utilization at recommended min node count

# Operational safety limits (configurable)
MAX_REDUCTION_PERCENT=${MAX_REDUCTION_PERCENT:-50}  # Maximum % reduction in one recommendation (default: 50%)
MIN_USER_POOL_NODES=${MIN_USER_POOL_NODES:-5}      # Minimum nodes for non-system pools (default: 5)
MIN_SYSTEM_POOL_NODES=${MIN_SYSTEM_POOL_NODES:-3}  # Minimum nodes for system pools (default: 3)

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
progress() { printf "🔍 [%s] %s\n" "$(date '+%H:%M:%S')" "$*" >&2; }

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

# Azure VM Pricing Database (Pay-as-you-go pricing in USD per month - 2024 estimates)
# Focused on common AKS node VM types
get_azure_vm_cost() {
    local vm_size="$1"
    local region="${2:-eastus}"  # Default region for pricing
    
    # Convert to lowercase for comparison
    local vm_lower=$(echo "$vm_size" | tr '[:upper:]' '[:lower:]')
    
    # Standard D-series (General Purpose)
    case "$vm_lower" in
        # D-series v3
        standard_d2s_v3) echo "70.08" ;;
        standard_d4s_v3) echo "140.16" ;;
        standard_d8s_v3) echo "280.32" ;;
        standard_d16s_v3) echo "560.64" ;;
        standard_d32s_v3) echo "1121.28" ;;
        standard_d48s_v3) echo "1681.92" ;;
        standard_d64s_v3) echo "2242.56" ;;
        
        # D-series v4 (Intel)
        standard_d2s_v4) echo "69.35" ;;
        standard_d4s_v4) echo "138.70" ;;
        standard_d8s_v4) echo "277.40" ;;
        standard_d16s_v4) echo "554.80" ;;
        standard_d32s_v4) echo "1109.60" ;;
        standard_d48s_v4) echo "1664.40" ;;
        standard_d64s_v4) echo "2219.20" ;;
        standard_d96s_v4) echo "3328.80" ;;
        
        # D-series v4 AMD (Das_v4)
        standard_d2as_v4) echo "58.40" ;;
        standard_d4as_v4) echo "116.80" ;;
        standard_d8as_v4) echo "233.60" ;;
        standard_d16as_v4) echo "467.20" ;;
        standard_d32as_v4) echo "934.40" ;;
        standard_d48as_v4) echo "1401.60" ;;
        standard_d64as_v4) echo "1868.80" ;;
        standard_d96as_v4) echo "3358.00" ;;
        
        # D-series v5
        standard_d2s_v5) echo "70.08" ;;
        standard_d4s_v5) echo "140.16" ;;
        standard_d8s_v5) echo "280.32" ;;
        standard_d16s_v5) echo "560.64" ;;
        standard_d16ds_v5) echo "560.64" ;;
        standard_d32s_v5) echo "1121.28" ;;
        standard_d48s_v5) echo "1681.92" ;;
        standard_d64s_v5) echo "2242.56" ;;
        standard_d96s_v5) echo "3363.84" ;;
        
        # D-series v5 AMD (Dads_v5)
        standard_d2ads_v5) echo "58.40" ;;
        standard_d4ads_v5) echo "116.80" ;;
        standard_d8ads_v5) echo "233.60" ;;
        standard_d16ads_v5) echo "467.20" ;;
        standard_d32ads_v5) echo "934.40" ;;
        standard_d48ads_v5) echo "1401.60" ;;
        standard_d64ads_v5) echo "1868.80" ;;
        standard_d96ads_v5) echo "2803.20" ;;
        
        # Standard E-series (Memory Optimized)
        # E-series v3
        standard_e2s_v3) echo "146.00" ;;
        standard_e4s_v3) echo "292.00" ;;
        standard_e8s_v3) echo "584.00" ;;
        standard_e16s_v3) echo "1168.00" ;;
        standard_e32s_v3) echo "2336.00" ;;
        standard_e48s_v3) echo "3504.00" ;;
        standard_e64s_v3) echo "4672.00" ;;
        
        # E-series v4 (Intel)
        standard_e2s_v4) echo "116.80" ;;
        standard_e4s_v4) echo "233.60" ;;
        standard_e8s_v4) echo "467.20" ;;
        standard_e16s_v4) echo "934.40" ;;
        standard_e32s_v4) echo "1868.80" ;;
        standard_e48s_v4) echo "2803.20" ;;
        standard_e64s_v4) echo "3737.60" ;;
        standard_e96s_v4) echo "5606.40" ;;
        
        # E-series v4 AMD (Eas_v4)
        standard_e2as_v4) echo "116.80" ;;
        standard_e4as_v4) echo "233.60" ;;
        standard_e8as_v4) echo "467.20" ;;
        standard_e16as_v4) echo "934.40" ;;
        standard_e32as_v4) echo "1868.80" ;;
        standard_e48as_v4) echo "2803.20" ;;
        standard_e64as_v4) echo "3737.60" ;;
        standard_e96as_v4) echo "5606.40" ;;
        
        # E-series v5
        standard_e2s_v5) echo "146.00" ;;
        standard_e4s_v5) echo "292.00" ;;
        standard_e8s_v5) echo "584.00" ;;
        standard_e16s_v5) echo "1168.00" ;;
        standard_e32s_v5) echo "2336.00" ;;
        standard_e48s_v5) echo "3504.00" ;;
        standard_e64s_v5) echo "4672.00" ;;
        standard_e96s_v5) echo "7008.00" ;;
        
        # E-series v5 AMD (Eads_v5)
        standard_e2ads_v5) echo "116.80" ;;
        standard_e4ads_v5) echo "233.60" ;;
        standard_e8ads_v5) echo "467.20" ;;
        standard_e16ads_v5) echo "934.40" ;;
        standard_e32ads_v5) echo "1868.80" ;;
        standard_e48ads_v5) echo "2803.20" ;;
        standard_e64ads_v5) echo "3737.60" ;;
        standard_e96ads_v5) echo "5606.40" ;;
        
        # Standard F-series (Compute Optimized)
        standard_f2s_v2) echo "61.32" ;;
        standard_f4s_v2) echo "122.64" ;;
        standard_f8s_v2) echo "245.28" ;;
        standard_f16s_v2) echo "490.56" ;;
        standard_f32s_v2) echo "981.12" ;;
        
        # Standard B-series (Burstable)
        standard_b2s) echo "30.37" ;;
        standard_b2ms) echo "60.74" ;;
        standard_b4ms) echo "121.47" ;;
        standard_b8ms) echo "242.93" ;;
        
        # Standard A-series (Basic)
        standard_a2_v2) echo "58.40" ;;
        standard_a4_v2) echo "116.80" ;;
        standard_a8_v2) echo "233.60" ;;
        
        *)
            # Default fallback for unknown VM types
            echo "140.16" ;;
    esac
}

# Get VM specs (vCPUs and RAM in GB)
get_vm_specs() {
    local vm_size="$1"
    local vm_lower=$(echo "$vm_size" | tr '[:upper:]' '[:lower:]')
    
    case "$vm_lower" in
        # D-series v3/v4/v5 (Intel/AMD variants)
        standard_d2s_v3|standard_d2s_v4|standard_d2s_v5|standard_d2as_v4|standard_d2ads_v5) echo "2 8" ;;
        standard_d4s_v3|standard_d4s_v4|standard_d4s_v5|standard_d4as_v4|standard_d4ads_v5) echo "4 16" ;;
        standard_d8s_v3|standard_d8s_v4|standard_d8s_v5|standard_d8as_v4|standard_d8ads_v5) echo "8 32" ;;
        standard_d16s_v3|standard_d16s_v4|standard_d16s_v5|standard_d16ds_v5|standard_d16as_v4|standard_d16ads_v5) echo "16 64" ;;
        standard_d32s_v3|standard_d32s_v4|standard_d32s_v5|standard_d32as_v4|standard_d32ads_v5) echo "32 128" ;;
        standard_d48s_v3|standard_d48s_v4|standard_d48s_v5|standard_d48as_v4|standard_d48ads_v5) echo "48 192" ;;
        standard_d64s_v3|standard_d64s_v4|standard_d64s_v5|standard_d64as_v4|standard_d64ads_v5) echo "64 256" ;;
        standard_d96s_v4|standard_d96s_v5|standard_d96as_v4|standard_d96ads_v5) echo "96 384" ;;
        
        # E-series v3/v4/v5 (Intel/AMD variants)
        standard_e2s_v3|standard_e2s_v4|standard_e2s_v5|standard_e2as_v4|standard_e2ads_v5) echo "2 16" ;;
        standard_e4s_v3|standard_e4s_v4|standard_e4s_v5|standard_e4as_v4|standard_e4ads_v5) echo "4 32" ;;
        standard_e8s_v3|standard_e8s_v4|standard_e8s_v5|standard_e8as_v4|standard_e8ads_v5) echo "8 64" ;;
        standard_e16s_v3|standard_e16s_v4|standard_e16s_v5|standard_e16as_v4|standard_e16ads_v5) echo "16 128" ;;
        standard_e32s_v3|standard_e32s_v4|standard_e32s_v5|standard_e32as_v4|standard_e32ads_v5) echo "32 256" ;;
        standard_e48s_v3|standard_e48s_v4|standard_e48s_v5|standard_e48as_v4|standard_e48ads_v5) echo "48 384" ;;
        standard_e64s_v3|standard_e64s_v4|standard_e64s_v5|standard_e64as_v4|standard_e64ads_v5) echo "64 512" ;;
        standard_e96s_v4|standard_e96s_v5|standard_e96as_v4|standard_e96ads_v5) echo "96 672" ;;
        
        # F-series v2
        standard_f2s_v2) echo "2 4" ;;
        standard_f4s_v2) echo "4 8" ;;
        standard_f8s_v2) echo "8 16" ;;
        standard_f16s_v2) echo "16 32" ;;
        standard_f32s_v2) echo "32 64" ;;
        
        # B-series
        standard_b2s) echo "2 4" ;;
        standard_b2ms) echo "2 8" ;;
        standard_b4ms) echo "4 16" ;;
        standard_b8ms) echo "8 32" ;;
        
        # A-series v2
        standard_a2_v2) echo "2 4" ;;
        standard_a4_v2) echo "4 8" ;;
        standard_a8_v2) echo "8 16" ;;
        
        *)
            # Default fallback
            echo "4 16" ;;
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

# Get AKS clusters for a subscription
get_aks_clusters() {
    local subscription_id="$1"
    local resource_group="${2:-}"
    
    if [[ -n "$resource_group" ]]; then
        az aks list --subscription "$subscription_id" --resource-group "$resource_group" -o json 2>/dev/null || echo '[]'
    else
        az aks list --subscription "$subscription_id" -o json 2>/dev/null || echo '[]'
    fi
}

# Get node pools for an AKS cluster
get_node_pools() {
    local cluster_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    
    az aks nodepool list --cluster-name "$cluster_name" --resource-group "$resource_group" --subscription "$subscription_id" -o json 2>/dev/null || echo '[]'
}

# Get peak CPU utilization for a node pool over the lookback period
get_peak_cpu_utilization() {
    local cluster_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    local node_pool_name="$4"
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$LOOKBACK_DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    # Get cluster resource ID
    local cluster_id=$(az aks show --name "$cluster_name" --resource-group "$resource_group" --subscription "$subscription_id" --query "id" -o tsv 2>/dev/null || echo "")
    
    if [[ -z "$cluster_id" ]]; then
        echo "0"
        return
    fi
    
    # Query for node CPU percentage
    # Note: AKS metrics are at the cluster level, we approximate by node pool scaling
    local peak_cpu=$(az monitor metrics list \
        --resource "$cluster_id" \
        --metric "node_cpu_usage_percentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Maximum \
        --query "value[0].timeseries[0].data[].maximum | max(@)" \
        -o tsv 2>/dev/null || echo "0")
    
    # If we got no data, try alternative metric
    if [[ "$peak_cpu" == "0" || -z "$peak_cpu" || "$peak_cpu" == "null" ]]; then
        peak_cpu=$(az monitor metrics list \
            --resource "$cluster_id" \
            --metric "kube_node_status_allocatable_cpu_cores" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --interval PT1H \
            --aggregation Average \
            --query "value[0].timeseries[0].data[].average | max(@)" \
            -o tsv 2>/dev/null || echo "0")
    fi
    
    # Return the value or 0 if unavailable
    if [[ -z "$peak_cpu" || "$peak_cpu" == "null" ]]; then
        echo "0"
    else
        printf "%.2f" "$peak_cpu"
    fi
}

# Get peak memory utilization for a node pool over the lookback period
get_peak_memory_utilization() {
    local cluster_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    local node_pool_name="$4"
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$LOOKBACK_DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    # Get cluster resource ID
    local cluster_id=$(az aks show --name "$cluster_name" --resource-group "$resource_group" --subscription "$subscription_id" --query "id" -o tsv 2>/dev/null || echo "")
    
    if [[ -z "$cluster_id" ]]; then
        echo "0"
        return
    fi
    
    # Query for node memory percentage
    local peak_memory=$(az monitor metrics list \
        --resource "$cluster_id" \
        --metric "node_memory_working_set_percentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Maximum \
        --query "value[0].timeseries[0].data[].maximum | max(@)" \
        -o tsv 2>/dev/null || echo "0")
    
    # If we got no data, try alternative metric
    if [[ "$peak_memory" == "0" || -z "$peak_memory" || "$peak_memory" == "null" ]]; then
        peak_memory=$(az monitor metrics list \
            --resource "$cluster_id" \
            --metric "node_memory_rss_percentage" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --interval PT1H \
            --aggregation Maximum \
            --query "value[0].timeseries[0].data[].maximum | max(@)" \
            -o tsv 2>/dev/null || echo "0")
    fi
    
    # Return the value or 0 if unavailable
    if [[ -z "$peak_memory" || "$peak_memory" == "null" ]]; then
        echo "0"
    else
        printf "%.2f" "$peak_memory"
    fi
}

# Get average CPU utilization for a node pool over the lookback period
get_average_cpu_utilization() {
    local cluster_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    local node_pool_name="$4"
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$LOOKBACK_DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    # Get cluster resource ID
    local cluster_id=$(az aks show --name "$cluster_name" --resource-group "$resource_group" --subscription "$subscription_id" --query "id" -o tsv 2>/dev/null || echo "")
    
    if [[ -z "$cluster_id" ]]; then
        echo "0"
        return
    fi
    
    # Query for node CPU percentage - AVERAGE aggregation
    # Get all average values and calculate the mean in bash
    local avg_values=$(az monitor metrics list \
        --resource "$cluster_id" \
        --metric "node_cpu_usage_percentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average \
        --query "value[0].timeseries[0].data[].average" \
        -o tsv 2>/dev/null)
    
    # Calculate average in bash
    if [[ -z "$avg_values" || "$avg_values" == "null" ]]; then
        echo "0"
        return
    fi
    
    local sum=0
    local count=0
    while read -r val; do
        if [[ -n "$val" && "$val" != "null" ]]; then
            sum=$(echo "scale=4; $sum + $val" | bc -l)
            ((count++))
        fi
    done <<< "$avg_values"
    
    if [[ $count -eq 0 ]]; then
        echo "0"
    else
        local avg_cpu=$(echo "scale=2; $sum / $count" | bc -l)
        printf "%.2f" "$avg_cpu"
    fi
}

# Get average memory utilization for a node pool over the lookback period
get_average_memory_utilization() {
    local cluster_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    local node_pool_name="$4"
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$LOOKBACK_DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    # Get cluster resource ID
    local cluster_id=$(az aks show --name "$cluster_name" --resource-group "$resource_group" --subscription "$subscription_id" --query "id" -o tsv 2>/dev/null || echo "")
    
    if [[ -z "$cluster_id" ]]; then
        echo "0"
        return
    fi
    
    # Query for node memory percentage - AVERAGE aggregation
    # Get all average values and calculate the mean in bash
    local avg_values=$(az monitor metrics list \
        --resource "$cluster_id" \
        --metric "node_memory_working_set_percentage" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average \
        --query "value[0].timeseries[0].data[].average" \
        -o tsv 2>/dev/null)
    
    # Calculate average in bash
    if [[ -z "$avg_values" || "$avg_values" == "null" ]]; then
        echo "0"
        return
    fi
    
    local sum=0
    local count=0
    while read -r val; do
        if [[ -n "$val" && "$val" != "null" ]]; then
            sum=$(echo "scale=4; $sum + $val" | bc -l)
            ((count++))
        fi
    done <<< "$avg_values"
    
    if [[ $count -eq 0 ]]; then
        echo "0"
    else
        local avg_memory=$(echo "scale=2; $sum / $count" | bc -l)
        printf "%.2f" "$avg_memory"
    fi
}

# Suggest alternative VM sizes based on utilization
suggest_alternative_vm_size() {
    local current_vm="$1"
    local peak_cpu_percent="$2"
    local peak_memory_percent="$3"
    
    # Get current VM specs
    local specs=$(get_vm_specs "$current_vm")
    local current_vcpus=$(echo "$specs" | awk '{print $1}')
    local current_ram=$(echo "$specs" | awk '{print $2}')
    
    # Determine if we need more CPU or memory focus
    local cpu_constrained=false
    local memory_constrained=false
    
    if (( $(echo "$peak_cpu_percent > 70" | bc -l) )); then
        cpu_constrained=true
    fi
    
    if (( $(echo "$peak_memory_percent > 70" | bc -l) )); then
        memory_constrained=true
    fi
    
    # If both are well below thresholds, suggest downsizing
    if (( $(echo "$peak_cpu_percent < $CPU_OPTIMIZATION_THRESHOLD" | bc -l) )) && \
       (( $(echo "$peak_memory_percent < $MEMORY_OPTIMIZATION_THRESHOLD" | bc -l) )); then
        
        # Suggest smaller VM in same series
        local vm_lower=$(echo "$current_vm" | tr '[:upper:]' '[:lower:]')
        local suggestion=""
        
        # Extract series and size
        if [[ "$vm_lower" =~ standard_([def])([0-9]+).*_v([345]) ]]; then
            local series="${BASH_REMATCH[1]}"
            local size="${BASH_REMATCH[2]}"
            local version="${BASH_REMATCH[3]}"
            
            # Suggest half the size
            local new_size=$((size / 2))
            if [[ $new_size -ge 2 ]]; then
                suggestion="Standard_${series^^}${new_size}s_v${version}"
            fi
        fi
        
        echo "$suggestion"
        return
    fi
    
    # If CPU constrained, suggest compute-optimized
    if [[ "$cpu_constrained" == true && "$memory_constrained" == false ]]; then
        case "$current_vcpus" in
            2) echo "Standard_F2s_v2" ;;
            4) echo "Standard_F4s_v2" ;;
            8) echo "Standard_F8s_v2" ;;
            16) echo "Standard_F16s_v2" ;;
            *) echo "" ;;
        esac
        return
    fi
    
    # If memory constrained, suggest memory-optimized
    if [[ "$memory_constrained" == true && "$cpu_constrained" == false ]]; then
        case "$current_vcpus" in
            2) echo "Standard_E2s_v4" ;;
            4) echo "Standard_E4s_v4" ;;
            8) echo "Standard_E8s_v4" ;;
            16) echo "Standard_E16s_v4" ;;
            *) echo "" ;;
        esac
        return
    fi
    
    # No clear recommendation
    echo ""
}

# Analyze a single node pool
analyze_node_pool() {
    local cluster_name="$1"
    local cluster_resource_group="$2"
    local subscription_id="$3"
    local subscription_name="$4"
    local node_pool_data="$5"
    
    local pool_name=$(echo "$node_pool_data" | jq -r '.name')
    local vm_size=$(echo "$node_pool_data" | jq -r '.vmSize')
    local current_count=$(echo "$node_pool_data" | jq -r '.count // 0')
    local min_count=$(echo "$node_pool_data" | jq -r '.minCount // .count')
    local max_count=$(echo "$node_pool_data" | jq -r '.maxCount // .count')
    local enable_autoscale=$(echo "$node_pool_data" | jq -r '.enableAutoScaling // false')
    local os_type=$(echo "$node_pool_data" | jq -r '.osType // "Linux"')
    
    log "  Analyzing Node Pool: $pool_name"
    log "    VM Size: $vm_size"
    log "    Current Node Count: $current_count"
    
    if [[ "$enable_autoscale" == "true" ]]; then
        log "    Autoscaling: Enabled (min: $min_count, max: $max_count)"
    else
        log "    Autoscaling: Disabled"
    fi
    
    # Get both average and peak utilization metrics
    progress "  Querying metrics for node pool: $pool_name (this may take a moment...)"
    local avg_cpu=$(get_average_cpu_utilization "$cluster_name" "$cluster_resource_group" "$subscription_id" "$pool_name")
    local avg_memory=$(get_average_memory_utilization "$cluster_name" "$cluster_resource_group" "$subscription_id" "$pool_name")
    local peak_cpu=$(get_peak_cpu_utilization "$cluster_name" "$cluster_resource_group" "$subscription_id" "$pool_name")
    local peak_memory=$(get_peak_memory_utilization "$cluster_name" "$cluster_resource_group" "$subscription_id" "$pool_name")
    
    log "    Average CPU Utilization (${LOOKBACK_DAYS}d): ${avg_cpu}%"
    log "    Average Memory Utilization (${LOOKBACK_DAYS}d): ${avg_memory}%"
    log "    Peak CPU Utilization (${LOOKBACK_DAYS}d): ${peak_cpu}%"
    log "    Peak Memory Utilization (${LOOKBACK_DAYS}d): ${peak_memory}%"
    
    # Calculate costs
    local monthly_cost_per_vm=$(get_azure_vm_cost "$vm_size")
    local msrp_monthly_cost=$(echo "scale=2; $monthly_cost_per_vm * $current_count" | bc -l)
    local current_monthly_cost=$(apply_discount "$msrp_monthly_cost")
    
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        log "    Current Monthly Cost: \$$current_monthly_cost (MSRP: \$$msrp_monthly_cost, ${DISCOUNT_PERCENTAGE}% discount)"
    else
        log "    Current Monthly Cost: \$$current_monthly_cost"
    fi
    
    # Determine if optimization is possible
    local optimization_found=false
    local optimization_details=""
    local optimization_savings=0
    local severity=4
    
    # Check if metrics are available
    if [[ "$peak_cpu" == "0" && "$peak_memory" == "0" && "$avg_cpu" == "0" && "$avg_memory" == "0" ]]; then
        log "    ⚠️  Unable to retrieve utilization metrics for this node pool"
        log "    This may be due to insufficient monitoring data or permissions"
        return
    fi
    
    # Scenario 1: Both CPU and memory are underutilized - suggest reducing min node count
    if (( $(echo "$peak_cpu < $CPU_OPTIMIZATION_THRESHOLD" | bc -l) )) && \
       (( $(echo "$peak_memory < $MEMORY_OPTIMIZATION_THRESHOLD" | bc -l) )) && \
       [[ "$enable_autoscale" == "true" ]] && [[ $min_count -gt 1 ]]; then
        
        optimization_found=true
        
        # Calculate required nodes based on AVERAGE utilization (for minimum nodes)
        local avg_util=$(echo "$avg_cpu > $avg_memory" | bc -l)
        [[ "$avg_util" == "1" ]] && avg_util=$avg_cpu || avg_util=$avg_memory
        
        # Calculate peak utilization (for maximum nodes)
        local peak_util=$(echo "$peak_cpu > $peak_memory" | bc -l)
        [[ "$peak_util" == "1" ]] && peak_util=$peak_cpu || peak_util=$peak_memory
        
        # Required nodes for MINIMUM = (avg_util% / TARGET_UTILIZATION%) * current_count
        local required_min_nodes_float=$(echo "scale=2; ($avg_util / $TARGET_UTILIZATION_PERCENT) * $current_count" | bc -l)
        local required_min_nodes=$(printf "%.0f" "$required_min_nodes_float")
        [[ $required_min_nodes -lt 1 ]] && required_min_nodes=1
        
        # Apply safety margin: recommended_min = required * (1 + safety_margin/100)
        local safety_factor=$(echo "scale=4; 1 + ($MIN_NODE_SAFETY_MARGIN_PERCENT / 100)" | bc -l)
        local suggested_min_count_float=$(echo "scale=2; $required_min_nodes * $safety_factor" | bc -l)
        local suggested_min_count=$(printf "%.0f" "$suggested_min_count_float")
        [[ $suggested_min_count -lt 1 ]] && suggested_min_count=1
        
        # Cap at current min to avoid recommending increases
        [[ $suggested_min_count -gt $min_count ]] && suggested_min_count=$min_count
        
        # Apply minimum node pool floors
        local node_floor=$MIN_USER_POOL_NODES
        local floor_reason="minimum user pool size"
        
        if [[ "$pool_name" == *"system"* ]]; then
            node_floor=$MIN_SYSTEM_POOL_NODES
            floor_reason="minimum system pool size"
        fi
        
        if [[ $suggested_min_count -lt $node_floor ]]; then
            suggested_min_count=$node_floor
        fi
        
        # Apply maximum reduction percentage limit (prevent extreme recommendations)
        local max_reduction_count=$(echo "scale=2; $min_count * (1 - ($MAX_REDUCTION_PERCENT / 100))" | bc)
        local max_reduction_count_int=$(printf "%.0f" "$max_reduction_count")
        [[ $max_reduction_count_int -lt $node_floor ]] && max_reduction_count_int=$node_floor
        
        log "    Debug: Capacity planning calculations:"
        log "      Required min nodes (avg util / target): $required_min_nodes"
        log "      After safety margin (${MIN_NODE_SAFETY_MARGIN_PERCENT}%): $(printf "%.0f" "$suggested_min_count_float") → $suggested_min_count"
        log "      After floor check ($node_floor): currently $suggested_min_count"
        log "      Max reduction floor (50% of $min_count): $max_reduction_count_int"
        
        local reduction_warning=""
        if [[ $suggested_min_count -lt $max_reduction_count_int ]]; then
            local original_suggestion=$suggested_min_count
            suggested_min_count=$max_reduction_count_int
            log "      Applied max reduction cap: $original_suggestion → $suggested_min_count"
            reduction_warning="⚠️  GRADUAL REDUCTION RECOMMENDED: Calculation suggested $original_suggestion nodes, but limiting to $suggested_min_count to cap reduction at ${MAX_REDUCTION_PERCENT}% per change. Consider multiple phased reductions."
        fi
        
        # Warning for suspicious metrics (0% average but high peak suggests monitoring issues)
        local metrics_warning=""
        if (( $(echo "$avg_util < 5" | bc -l) )) && (( $(echo "$peak_util > 20" | bc -l) )); then
            metrics_warning="⚠️  METRICS ANOMALY DETECTED: Average utilization is very low ($avg_util%) but peak is ${peak_util}%. This may indicate:
   - Monitoring data collection issues
   - Metrics not aggregating correctly across all nodes
   - Very bursty workload with long idle periods
   Verify metrics accuracy before implementing recommendations."
        fi
        
        # Validate max node count is sufficient for peak loads with buffer
        # Required nodes for MAXIMUM = (peak_util% / TARGET_UTILIZATION%) * current_count
        local required_max_nodes_float=$(echo "scale=2; ($peak_util / $TARGET_UTILIZATION_PERCENT) * $current_count" | bc -l)
        local required_max_nodes=$(printf "%.0f" "$required_max_nodes_float")
        [[ $required_max_nodes -lt 1 ]] && required_max_nodes=1
        
        local recommended_max_float=$(echo "scale=2; $required_max_nodes * (1 + ($MAX_NODE_SAFETY_MARGIN_PERCENT / 100))" | bc -l)
        local recommended_max=$(printf "%.0f" "$recommended_max_float")
        local max_sufficient="Yes"
        local max_warning=""
        if [[ $max_count -lt $recommended_max ]]; then
            max_sufficient="No"
            max_warning="⚠️ WARNING: Current max ($max_count) may be insufficient for peak loads. Consider increasing to $recommended_max or higher."
        fi
        
        # Skip creating an issue if the suggested count is the same as or greater than current
        if [[ $suggested_min_count -ge $min_count ]]; then
            log "    ℹ️  Underutilized but minimum node count already optimal (suggested: $suggested_min_count, current: $min_count)"
            return
        fi
        
        local nodes_saved=$((min_count - suggested_min_count))
        optimization_savings=$(echo "scale=2; $monthly_cost_per_vm * $nodes_saved" | bc -l)
        optimization_savings=$(apply_discount "$optimization_savings")
        local annual_savings=$(echo "scale=2; $optimization_savings * 12" | bc -l)
        
        optimization_details="UNDERUTILIZED NODE POOL - REDUCE MINIMUM NODE COUNT:

Node Pool: $pool_name
Cluster: $cluster_name
Resource Group: $cluster_resource_group
Subscription: $subscription_name ($subscription_id)

CURRENT CONFIGURATION:
- VM Size: $vm_size
- Current Node Count: $current_count
- Autoscaling: min=$min_count, max=$max_count
- Current Monthly Cost: \$$current_monthly_cost

UTILIZATION ANALYSIS ($LOOKBACK_DAYS days):
- Average CPU: ${avg_cpu}% | Peak CPU: ${peak_cpu}%
- Average Memory: ${avg_memory}% | Peak Memory: ${peak_memory}%
- Higher Average Utilization: ${avg_util}%
- Higher Peak Utilization: ${peak_util}%
- Peak Optimization Thresholds: CPU ${CPU_OPTIMIZATION_THRESHOLD}%, Memory ${MEMORY_OPTIMIZATION_THRESHOLD}%

CAPACITY PLANNING METHODOLOGY:
The recommendation uses a two-tier approach:
1. MINIMUM nodes based on AVERAGE utilization (handles typical workload)
2. MAXIMUM nodes based on PEAK utilization (handles traffic spikes)

MINIMUM NODE CALCULATION (based on average utilization):
- Current average utilization: ${avg_util}%
- Target utilization: ${TARGET_UTILIZATION_PERCENT}%
- Required nodes at target: $required_min_nodes nodes
- Safety margin applied: ${MIN_NODE_SAFETY_MARGIN_PERCENT}% (${safety_factor}x multiplier)
- Recommended minimum: $suggested_min_count nodes$(if [[ "$pool_name" == *"system"* ]]; then echo " (system pool floor is 3 nodes)"; fi)

MAXIMUM NODE VALIDATION (based on peak utilization):
- Current peak utilization: ${peak_util}%
- Required nodes at peak: $required_max_nodes nodes
- Safety margin applied: ${MAX_NODE_SAFETY_MARGIN_PERCENT}%
- Recommended maximum: $recommended_max nodes
- Current maximum: $max_count nodes
- Max capacity sufficient: $max_sufficient$(if [[ -n "$max_warning" ]]; then echo "

$max_warning"; fi)

RECOMMENDATION:
Reduce minimum node count from $min_count to $suggested_min_count nodes

This recommendation ensures the node pool can handle typical workloads (average utilization)
while maintaining sufficient ceiling capacity (maximum nodes) for traffic spikes.$(if [[ -n "$reduction_warning" ]]; then echo "

$reduction_warning"; fi)$(if [[ -n "$metrics_warning" ]]; then echo "

$metrics_warning"; fi)

OPERATIONAL SAFETY LIMITS APPLIED:
- Minimum user pool size: $MIN_USER_POOL_NODES nodes
- Minimum system pool size: $MIN_SYSTEM_POOL_NODES nodes  
- Maximum reduction per change: ${MAX_REDUCTION_PERCENT}%
- Final recommendation: $suggested_min_count nodes ($floor_reason applied)

PROJECTED SAVINGS:
- Nodes Reduced: $nodes_saved
- Monthly Savings: \$$optimization_savings
- Annual Savings: \$$annual_savings

RATIONALE:
Both CPU and memory utilization are well below optimal thresholds. The calculation shows:
1. At average load ($avg_util% utilization), you need ~$required_min_nodes nodes
2. With ${MIN_NODE_SAFETY_MARGIN_PERCENT}% safety margin, minimum should be $suggested_min_count nodes
3. At peak load ($peak_util% utilization), maximum capacity of $recommended_max nodes handles spikes
4. Current min of $min_count is ${nodes_saved} nodes more than needed
5. Autoscaler can still scale up to $max_count for unexpected traffic spikes

IMPLEMENTATION STRATEGY:
1. **Pre-Implementation** (Week 1):
   - Verify pod resource requests/limits are properly configured
   - Review historical metrics to confirm $LOOKBACK_DAYS-day analysis is representative
   - Test HPA (Horizontal Pod Autoscaler) is functioning correctly
   - Document current pod distribution and scheduling patterns

2. **Gradual Reduction** (Weeks 2-4):
   - Week 2: Reduce min nodes by 25% (from $min_count to $(($min_count - $nodes_saved / 4)))
   - Week 3: Reduce by another 25% (to $(($min_count - $nodes_saved / 2)))
   - Week 4: Complete reduction to $suggested_min_count nodes
   - Monitor for pod scheduling issues, latency increases, or autoscaler lag

3. **Post-Implementation** (Week 5+):
   - Monitor cluster autoscaler metrics and scale-up times
   - Validate cost savings match projections
   - Document new baseline performance metrics

RISKS & MITIGATION:
- Risk: Pod scheduling failures during rapid scale-up
  Mitigation: Max count ($max_count nodes) provides headroom; cluster autoscaler will scale
- Risk: Slower response to traffic spikes (autoscaler lag)
  Mitigation: Configure cluster-autoscaler for aggressive scale-up (--scale-up-delay-after-add=1m)
- Risk: Resource contention during min node operation
  Mitigation: With $suggested_min_count nodes at ${TARGET_UTILIZATION_PERCENT}% target utilization, headroom exists
- Risk: Pod evictions during scale-down
  Mitigation: Implement Pod Disruption Budgets (PDBs) for critical workloads"
        
        # Determine severity based on savings
        if (( $(echo "$optimization_savings > $HIGH_COST_THRESHOLD" | bc -l) )); then
            severity=2
        elif (( $(echo "$optimization_savings > $MEDIUM_COST_THRESHOLD" | bc -l) )); then
            severity=3
        fi
        
        add_issue "AKS Node Pool \`$pool_name\` in cluster \`$cluster_name\` - Reduce min nodes to $suggested_min_count (\$$optimization_savings/month savings)" \
                 "$optimization_details" \
                 "$severity" \
                 "Update node pool autoscaling: az aks nodepool update --cluster-name '$cluster_name' --name '$pool_name' --resource-group '$cluster_resource_group' --subscription '$subscription_id' --min-count $suggested_min_count\\nMonitor node utilization: az aks nodepool show --cluster-name '$cluster_name' --name '$pool_name' --resource-group '$cluster_resource_group' --subscription '$subscription_id'\\nCheck pod scheduling: kubectl get pods --all-namespaces -o wide | grep Pending"
    fi
    
    # Scenario 2: Suggest different VM size based on utilization patterns
    # NOTE: This is mutually exclusive with Scenario 1 - only recommend VM change if better than node reduction
    local suggested_vm=$(suggest_alternative_vm_size "$vm_size" "$peak_cpu" "$peak_memory")
    
    if [[ -n "$suggested_vm" && "$suggested_vm" != "$vm_size" ]]; then
        local suggested_vm_cost=$(get_azure_vm_cost "$suggested_vm")
        local suggested_msrp_monthly=$(echo "scale=2; $suggested_vm_cost * $current_count" | bc -l)
        local suggested_monthly_cost=$(apply_discount "$suggested_msrp_monthly")
        local vm_optimization_savings=$(echo "scale=2; $current_monthly_cost - $suggested_monthly_cost" | bc -l)
        local annual_vm_savings=$(echo "scale=2; $vm_optimization_savings * 12" | bc -l)
        
        # Skip VM recommendation if node count reduction already recommended and provides similar/better savings
        if [[ -n "$optimization_savings" ]] && (( $(echo "$optimization_savings >= $vm_optimization_savings * 0.9" | bc -l) )); then
            log "    ℹ️  Alternative VM type available ($suggested_vm) but node count reduction provides similar/better savings"
        # Only create issue if there are actual savings and it's better than other options
        elif (( $(echo "$vm_optimization_savings > 10" | bc -l) )); then
            optimization_found=true
            
            # Get VM specs for comparison
            local current_specs=$(get_vm_specs "$vm_size")
            local suggested_specs=$(get_vm_specs "$suggested_vm")
            
            optimization_details="ALTERNATIVE OPTIMIZATION - CONSIDER DIFFERENT NODE TYPE:

Node Pool: $pool_name
Cluster: $cluster_name
Resource Group: $cluster_resource_group
Subscription: $subscription_name ($subscription_id)

⚠️ NOTE: This is an ALTERNATIVE to reducing node count. Choose ONE approach:
   - Option A: Reduce minimum node count (if recommended separately)
   - Option B: Change VM type (this recommendation)
   Do NOT implement both simultaneously.

CURRENT CONFIGURATION:
- VM Size: $vm_size ($current_specs vCPUs, RAM GB)
- Node Count: $current_count
- Autoscaling: min=$min_count, max=$max_count
- Current Monthly Cost: \$$current_monthly_cost

UTILIZATION ANALYSIS ($LOOKBACK_DAYS days):
- Peak CPU: ${peak_cpu}%
- Peak Memory: ${peak_memory}%

RECOMMENDATION:
Change VM size from $vm_size to $suggested_vm ($suggested_specs vCPUs, RAM GB)

This maintains the same node count ($current_count nodes) but uses smaller, more
appropriately-sized VMs to match your actual workload requirements.

PROJECTED SAVINGS:
- Current Monthly Cost: \$$current_monthly_cost
- Suggested Monthly Cost: \$$suggested_monthly_cost
- Monthly Savings: \$$vm_optimization_savings
- Annual Savings: \$$annual_vm_savings

RATIONALE:
The current VM size is over-provisioned for your workload utilization patterns:
- Current: $vm_size with $current_specs vCPUs/RAM
- Utilization: ${peak_cpu}% CPU, ${peak_memory}% memory at peak
- Suggested: $suggested_vm with $suggested_specs vCPUs/RAM provides better cost/performance ratio

DECISION CRITERIA:
Choose VM type change over node count reduction if:
✓ Workload requires consistent node availability (not bursty)
✓ Applications are sensitive to pod migration during autoscaling
✓ Simpler implementation path (one-time migration vs ongoing autoscaler tuning)
✓ Pod scheduling is complex and benefits from consistent node topology

Choose node count reduction if:
✓ Workload is bursty with predictable low-traffic periods
✓ Cost optimization is the primary goal
✓ Applications handle autoscaling gracefully
✓ You want to leverage autoscaler for dynamic cost optimization

IMPLEMENTATION:
1. **Pre-Migration** (Week 1):
   - Create new node pool with recommended VM size ($suggested_vm)
   - Configure same autoscaling settings (min=$min_count, max=$max_count)
   - Verify new pool comes online successfully

2. **Migration** (Week 2):
   - Cordon old node pool nodes (prevent new pod scheduling)
   - Gradually drain nodes (start with 10-20% of workload)
   - Monitor application performance and pod scheduling
   - Continue drain process in waves until complete

3. **Cleanup** (Week 3):
   - Validate all workloads running on new pool
   - Monitor for 1 week to ensure stability
   - Delete old node pool

4. **Post-Migration**:
   - Document new baseline performance metrics
   - Update runbooks and documentation
   - Validate cost savings in billing

Note: VM size cannot be changed in-place. This requires blue/green node pool migration."
            
            # Determine severity based on savings
            if (( $(echo "$vm_optimization_savings > $HIGH_COST_THRESHOLD" | bc -l) )); then
                severity=2
            elif (( $(echo "$vm_optimization_savings > $MEDIUM_COST_THRESHOLD" | bc -l) )); then
                severity=3
            fi
            
            add_issue "AKS Node Pool \`$pool_name\` in cluster \`$cluster_name\` - Consider switching to $suggested_vm (\$$vm_optimization_savings/month savings)" \
                     "$optimization_details" \
                     "$severity" \
                     "Create new node pool: az aks nodepool add --cluster-name '$cluster_name' --name '${pool_name}new' --resource-group '$cluster_resource_group' --subscription '$subscription_id' --node-vm-size '$suggested_vm' --node-count $current_count\\nCordon old nodes: kubectl cordon -l agentpool=$pool_name\\nDrain old nodes: kubectl drain -l agentpool=$pool_name --ignore-daemonsets --delete-emptydir-data\\nDelete old pool: az aks nodepool delete --cluster-name '$cluster_name' --name '$pool_name' --resource-group '$cluster_resource_group' --subscription '$subscription_id'"
        fi
    fi
    
    # Scenario 3: Static node pool with low utilization
    if [[ "$enable_autoscale" == "false" ]] && \
       (( $(echo "$peak_cpu < $CPU_UNDERUTILIZATION_THRESHOLD" | bc -l) )) && \
       (( $(echo "$peak_memory < $MEMORY_UNDERUTILIZATION_THRESHOLD" | bc -l) )) && \
       [[ $current_count -gt 1 ]]; then
        
        optimization_found=true
        local suggested_static_count=$(( (current_count + 1) / 2 ))
        [[ $suggested_static_count -lt 1 ]] && suggested_static_count=1
        
        # Safety check: System node pools should never go below 3 nodes
        if [[ "$pool_name" == *"system"* ]] && [[ $suggested_static_count -lt 3 ]]; then
            suggested_static_count=3
        fi
        
        # Skip creating an issue if the suggested count is the same as current
        if [[ $suggested_static_count -eq $current_count ]]; then
            log "    ℹ️  Underutilized but node count already optimal (system pool minimum is 3)"
            return
        fi
        
        local static_nodes_saved=$((current_count - suggested_static_count))
        local static_savings=$(echo "scale=2; $monthly_cost_per_vm * $static_nodes_saved" | bc -l)
        static_savings=$(apply_discount "$static_savings")
        local static_annual_savings=$(echo "scale=2; $static_savings * 12" | bc -l)
        
        optimization_details="STATIC NODE POOL OVER-PROVISIONED:

Node Pool: $pool_name
Cluster: $cluster_name
Resource Group: $cluster_resource_group
Subscription: $subscription_name ($subscription_id)

CURRENT CONFIGURATION:
- VM Size: $vm_size
- Current Node Count: $current_count (static)
- Autoscaling: DISABLED
- Current Monthly Cost: \$$current_monthly_cost

UTILIZATION ANALYSIS ($LOOKBACK_DAYS days):
- Peak CPU: ${peak_cpu}% (very low - threshold: ${CPU_UNDERUTILIZATION_THRESHOLD}%)
- Peak Memory: ${peak_memory}% (very low - threshold: ${MEMORY_UNDERUTILIZATION_THRESHOLD}%)

RECOMMENDATIONS:
Option 1: Reduce node count to $suggested_static_count nodes$(if [[ "$pool_name" == *"system"* ]]; then echo " (minimum 3 for system pools)"; fi)
Option 2: Enable autoscaling with min=$suggested_static_count, max=$current_count

PROJECTED SAVINGS (Option 1):
- Nodes Reduced: $static_nodes_saved
- Monthly Savings: \$$static_savings
- Annual Savings: \$$static_annual_savings

RATIONALE:
This node pool has autoscaling disabled and maintains a fixed node count regardless
of actual demand. Both CPU and memory utilization are significantly below thresholds,
indicating substantial over-provisioning. Either reducing the fixed node count or
enabling autoscaling will yield immediate cost savings.

RECOMMENDED APPROACH:
Enable autoscaling (Option 2) to allow dynamic scaling based on demand while
maintaining the ability to handle traffic spikes."
        
        # Determine severity based on savings
        if (( $(echo "$static_savings > $HIGH_COST_THRESHOLD" | bc -l) )); then
            severity=2
        elif (( $(echo "$static_savings > $MEDIUM_COST_THRESHOLD" | bc -l) )); then
            severity=3
        fi
        
        add_issue "AKS Static Node Pool \`$pool_name\` in cluster \`$cluster_name\` - Reduce to $suggested_static_count nodes or enable autoscaling (\$$static_savings/month savings)" \
                 "$optimization_details" \
                 "$severity" \
                 "Option 1 - Reduce node count: az aks nodepool scale --cluster-name '$cluster_name' --name '$pool_name' --resource-group '$cluster_resource_group' --subscription '$subscription_id' --node-count $suggested_static_count\\nOption 2 - Enable autoscaling: az aks nodepool update --cluster-name '$cluster_name' --name '$pool_name' --resource-group '$cluster_resource_group' --subscription '$subscription_id' --enable-cluster-autoscaler --min-count $suggested_static_count --max-count $current_count"
    fi
    
    if [[ "$optimization_found" == false ]]; then
        log "    ✅ Node pool appears to be well-optimized"
    fi
    
    hr
}

# Analyze AKS clusters in a subscription
analyze_aks_clusters_in_subscription() {
    local subscription_id="$1"
    local subscription_name="$2"
    local resource_groups="${3:-}"
    
    progress "Analyzing AKS clusters in subscription: $subscription_name"
    
    local clusters=""
    if [[ -n "$resource_groups" ]]; then
        IFS=',' read -ra RG_ARRAY <<< "$resource_groups"
        for rg in "${RG_ARRAY[@]}"; do
            rg=$(echo "$rg" | xargs)  # Trim whitespace
            local rg_clusters=$(get_aks_clusters "$subscription_id" "$rg")
            clusters=$(echo "$clusters" "$rg_clusters" | jq -s 'add')
        done
    else
        clusters=$(get_aks_clusters "$subscription_id")
    fi
    
    local cluster_count=$(echo "$clusters" | jq 'length')
    
    if [[ $cluster_count -eq 0 ]]; then
        log "No AKS clusters found in subscription: $subscription_name"
        progress "No AKS clusters found in subscription: $subscription_name"
        return
    fi
    
    progress "Found $cluster_count AKS cluster(s) in subscription: $subscription_name"
    log "Found $cluster_count AKS cluster(s) in subscription: $subscription_name ($subscription_id)"
    hr
    
    # Analyze each cluster
    echo "$clusters" | jq -c '.[]' | while read -r cluster_data; do
        local cluster_name=$(echo "$cluster_data" | jq -r '.name')
        local cluster_rg=$(echo "$cluster_data" | jq -r '.resourceGroup')
        local cluster_location=$(echo "$cluster_data" | jq -r '.location')
        local k8s_version=$(echo "$cluster_data" | jq -r '.kubernetesVersion')
        
        log "Analyzing AKS Cluster: $cluster_name"
        log "  Resource Group: $cluster_rg"
        log "  Location: $cluster_location"
        log "  Kubernetes Version: $k8s_version"
        
        progress "Analyzing cluster: $cluster_name"
        
        # Get node pools for this cluster
        local node_pools=$(get_node_pools "$cluster_name" "$cluster_rg" "$subscription_id")
        local pool_count=$(echo "$node_pools" | jq 'length')
        
        log "  Node Pools: $pool_count"
        
        if [[ $pool_count -eq 0 ]]; then
            log "  ⚠️  No node pools found for this cluster"
            hr
            continue
        fi
        
        # Analyze each node pool
        echo "$node_pools" | jq -c '.[]' | while read -r pool_data; do
            analyze_node_pool "$cluster_name" "$cluster_rg" "$subscription_id" "$subscription_name" "$pool_data"
        done
    done
}

# Generate summary report
generate_summary() {
    progress "Generating optimization summary"
    
    # Check if issues file exists and has content
    if [[ ! -f "$ISSUES_FILE" ]] || [[ ! -s "$ISSUES_FILE" ]]; then
        log ""
        log "=== AKS NODE POOL OPTIMIZATION SUMMARY ==="
        log "No optimization opportunities identified."
        log ""
        echo ""
        echo "✅ All AKS node pools appear to be well-optimized"
        return
    fi
    
    # Build cluster-level summary table
    progress "Building cluster-level cost savings summary"
    
    # Extract cluster information from issues and aggregate by cluster
    local cluster_summary=$(jq -r '
        group_by(.details | capture("Cluster: (?<cluster>[^\n]+)")) |
        map({
            cluster: .[0].details | capture("Cluster: (?<cluster>[^\n]+)").cluster,
            resource_group: .[0].details | capture("Resource Group: (?<rg>[^\n]+)").rg,
            subscription_id: .[0].details | capture("Subscription: [^(]+\\((?<sub>[^)]+)\\)").sub,
            subscription_name: .[0].details | capture("Subscription: (?<name>[^(]+)").name | ltrimstr(" ") | rtrimstr(" "),
            monthly_savings: [.[] | .title | capture("\\$(?<monthly>[0-9,]+\\.?[0-9]*)/month").monthly | gsub(","; "") | tonumber] | add,
            issue_count: length
        })' "$ISSUES_FILE" 2>/dev/null)
    
    # Build cluster summary table
    local cluster_table=""
    if [[ -n "$cluster_summary" ]]; then
        cluster_table="
=== COST SAVINGS BY CLUSTER ===

$(printf "%-40s %-45s %-20s %15s %15s\n" "CLUSTER" "RESOURCE GROUP" "ISSUES" "MONTHLY" "ANNUAL")
$(printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────")
$(echo "$cluster_summary" | jq -r '.[] | 
    "\(.cluster)|\(.resource_group)|\(.issue_count)|\(.monthly_savings)|\(.monthly_savings * 12)"' | 
    while IFS='|' read -r cluster rg issues monthly annual; do
        printf "%-40s %-45s %-20s %14s %14s\n" \
            "${cluster:0:40}" \
            "${rg:0:45}" \
            "$issues issue(s)" \
            "\$$(printf "%.2f" "$monthly")" \
            "\$$(printf "%.2f" "$annual")"
    done)
$(printf "%s\n" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────")

SUBSCRIPTION DETAILS:
$(echo "$cluster_summary" | jq -r '.[] | 
    "  • \(.cluster): \(.subscription_name) (\(.subscription_id))"' | sort -u)
"
    fi
    
    # Extract cost data and generate summary
    # Note: The regex now handles commas in numbers (e.g., 83,950.00)
    local total_monthly=$(jq -r '[.[] | .title | capture("\\$(?<monthly>[0-9,]+\\.?[0-9]*)/month").monthly | gsub(","; "") | tonumber] | add // 0' "$ISSUES_FILE" 2>/dev/null || echo "0")
    [[ "$total_monthly" == "null" || -z "$total_monthly" ]] && total_monthly="0"
    local total_annual=$(echo "scale=2; $total_monthly * 12" | bc -l 2>/dev/null || echo "0")
    [[ "$total_annual" == "null" || -z "$total_annual" ]] && total_annual="0"
    local issue_count=$(jq 'length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    local sev2_count=$(jq '[.[] | select(.severity == 2)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    local sev3_count=$(jq '[.[] | select(.severity == 3)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    local sev4_count=$(jq '[.[] | select(.severity == 4)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    
    # Generate summary report
    local summary_output="
=== AKS NODE POOL OPTIMIZATION SUMMARY ===
Date: $(date '+%Y-%m-%d %H:%M:%S UTC')
Analysis Period: Past $LOOKBACK_DAYS days

TOTAL POTENTIAL SAVINGS:
Monthly: \$$(printf "%.2f" $total_monthly)
Annual:  \$$(printf "%.2f" $total_annual)

BREAKDOWN BY SEVERITY:
Severity 2 (High Priority >\$10k/month): $sev2_count issues
Severity 3 (Medium Priority \$2k-\$10k/month): $sev3_count issues
Severity 4 (Low Priority <\$2k/month): $sev4_count issues
$cluster_table
TOP OPTIMIZATION OPPORTUNITIES:
$(jq -r 'sort_by(.title | capture("\\$(?<monthly>[0-9,]+\\.?[0-9]*)/month").monthly | gsub(","; "") | tonumber) | reverse | limit(5; .[]) | "- " + .title' "$ISSUES_FILE" 2>/dev/null || echo "- No opportunities identified")

CAPACITY PLANNING METHODOLOGY:
- Two-tier approach: MINIMUM nodes based on AVERAGE utilization, MAXIMUM nodes based on PEAK utilization
- This ensures cost-effective baseline capacity while maintaining ceiling for traffic spikes
- Safety Margin for Min Nodes: ${MIN_NODE_SAFETY_MARGIN_PERCENT}% (configurable via MIN_NODE_SAFETY_MARGIN_PERCENT)
- Safety Margin for Max Nodes: ${MAX_NODE_SAFETY_MARGIN_PERCENT}% (configurable via MAX_NODE_SAFETY_MARGIN_PERCENT)
- Target Utilization: ${TARGET_UTILIZATION_PERCENT}% (optimal resource efficiency)
- Formula (Min): Required = (Avg% / Target%) × Current, Recommended = Required × (1 + Safety%)
- Formula (Max): Required = (Peak% / Target%) × Current, Recommended = Required × (1 + Safety%)

KEY RECOMMENDATIONS:
1. Review capacity planning details in each recommendation
2. When multiple options exist (node reduction vs VM change), choose based on workload characteristics
3. Validate maximum node counts are sufficient for peak loads
4. Implement changes gradually with monitoring at each step
5. Ensure pod resource requests/limits are properly configured

OPERATIONAL SAFETY LIMITS:
- Maximum reduction per change: ${MAX_REDUCTION_PERCENT}% (configurable via MAX_REDUCTION_PERCENT)
- Minimum user pool nodes: ${MIN_USER_POOL_NODES} (configurable via MIN_USER_POOL_NODES)
- Minimum system pool nodes: ${MIN_SYSTEM_POOL_NODES} (configurable via MIN_SYSTEM_POOL_NODES)
- These limits prevent overly aggressive reductions and maintain operational stability

IMPLEMENTATION NOTES:
- All recommendations are based on $LOOKBACK_DAYS days of utilization data
- Recommendations capped at ${MAX_REDUCTION_PERCENT}% reduction - consider multiple phased changes for larger optimizations
- Metrics anomaly warnings indicate potential monitoring issues - verify before implementing
- Test changes in non-production environments first
- Never implement both node reduction AND VM type change simultaneously
- Configure cluster-autoscaler for aggressive scale-up to handle traffic spikes
"

    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        summary_output="${summary_output}
NOTE: All costs reflect a ${DISCOUNT_PERCENTAGE}% discount off MSRP."
    fi
    
    # Always show the summary if we have data
    if [[ "$total_monthly" != "0" && "$issue_count" != "0" ]]; then
        log "$summary_output"
        
        # Also output to console for immediate visibility
        echo ""
        echo "🎯 AKS OPTIMIZATION SUMMARY:"
        echo "==========================="
        echo "💰 Total Monthly Savings: \$$(printf "%.2f" $total_monthly)"
        echo "💰 Total Annual Savings:  \$$(printf "%.2f" $total_annual)"
        echo "📊 Optimization Opportunities: $issue_count"
        echo ""
        
        # Show cluster table if available
        if [[ -n "$cluster_summary" ]]; then
            echo "💵 COST SAVINGS BY CLUSTER:"
            echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
            printf "%-40s %-45s %-20s %15s %15s\n" "CLUSTER" "RESOURCE GROUP" "ISSUES" "MONTHLY" "ANNUAL"
            echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
            echo "$cluster_summary" | jq -r '.[] | 
                "\(.cluster)|\(.resource_group)|\(.issue_count)|\(.monthly_savings)|\(.monthly_savings * 12)"' | 
                while IFS='|' read -r cluster rg issues monthly annual; do
                    printf "%-40s %-45s %-20s %14s %14s\n" \
                        "${cluster:0:40}" \
                        "${rg:0:45}" \
                        "$issues issue(s)" \
                        "\$$(printf "%.2f" "$monthly")" \
                        "\$$(printf "%.2f" "$annual")"
                done
            echo "──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
            echo ""
        fi
        
        # Show top 3 biggest savings opportunities
        echo "🔥 TOP OPPORTUNITIES:"
        jq -r 'sort_by(.title | capture("\\$(?<monthly>[0-9,]+\\.?[0-9]*)/month").monthly | gsub(","; "") | tonumber) | reverse | limit(3; .[]) | "   • " + .title' "$ISSUES_FILE" 2>/dev/null || echo "   • No specific opportunities identified"
        echo ""
        
        echo "⚡ POTENTIAL ANNUAL IMPACT: \$$(printf "%.0f" $total_annual)"
        echo ""
    else
        log "No significant optimization opportunities identified."
        echo "✅ All AKS node pools appear to be well-optimized"
    fi
}

# Main analysis function
main() {
    # Initialize report
    printf "AKS Node Pool Optimization Analysis — %s\n" "$(date -Iseconds)" > "$REPORT_FILE"
    printf "Analysis Period: Past %s days\n" "$LOOKBACK_DAYS" >> "$REPORT_FILE"
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        printf "Discount Applied: %s%% off MSRP\n" "$DISCOUNT_PERCENTAGE" >> "$REPORT_FILE"
    fi
    hr
    
    progress "Starting AKS Node Pool Optimization Analysis"
    progress "Lookback period: $LOOKBACK_DAYS days"
    progress "Safety margins: Min nodes +${MIN_NODE_SAFETY_MARGIN_PERCENT}%, Max nodes +${MAX_NODE_SAFETY_MARGIN_PERCENT}%, Target utilization ${TARGET_UTILIZATION_PERCENT}%"
    progress "Operational limits: Max reduction ${MAX_REDUCTION_PERCENT}%, Min user pool ${MIN_USER_POOL_NODES} nodes, Min system pool ${MIN_SYSTEM_POOL_NODES} nodes"
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
    
    # Process each subscription
    for subscription_id in "${SUBSCRIPTION_ARRAY[@]}"; do
        subscription_id=$(echo "$subscription_id" | xargs)  # Trim whitespace
        
        progress "Processing subscription: $subscription_id"
        
        # Set subscription context
        az account set --subscription "$subscription_id" || {
            progress "Failed to set subscription context for: $subscription_id"
            continue
        }
        
        # Get subscription name
        local subscription_name=$(az account show --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null || echo "Unknown")
        
        log "Analyzing Subscription: $subscription_name ($subscription_id)"
        hr
        
        # Analyze AKS clusters in this subscription
        analyze_aks_clusters_in_subscription "$subscription_id" "$subscription_name" "$resource_groups"
    done
    
    # Finalize issues JSON
    echo "]" >> "$ISSUES_TMP"
    mv "$ISSUES_TMP" "$ISSUES_FILE"
    
    # Generate summary
    generate_summary
    
    progress "AKS Node Pool Optimization Analysis completed"
    log ""
    log "Analysis completed at $(date -Iseconds)"
    log "Issues file: $ISSUES_FILE"
    log "Report file: $REPORT_FILE"
}

# Run main analysis
main "$@"

