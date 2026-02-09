#!/bin/bash

# Azure Virtual Machine Optimization Analysis Script
# Analyzes VMs to identify cost optimization opportunities
# Focuses on: 1) Stopped-not-deallocated VMs, 2) Oversized/undersized VMs, 3) Reserved Instance opportunities
#
# Performance Features:
#   - Azure Resource Graph for 10-100x faster VM discovery
#   - Parallel metrics collection with controlled concurrency
#   - Scan modes: full (default), quick, sample

set -eo pipefail

# Source shared performance utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../libraries/Azure/azure_performance_utils.sh" 2>/dev/null || \
source "/home/runwhen/codecollection/libraries/Azure/azure_performance_utils.sh" 2>/dev/null || {
    echo "Warning: Performance utilities not found, using standard queries" >&2
}

# Environment variables expected:
# AZURE_SUBSCRIPTION_IDS - Comma-separated list of subscription IDs to analyze (required)
# AZURE_RESOURCE_GROUPS - Comma-separated list of resource groups to analyze (optional, defaults to all)
# COST_ANALYSIS_LOOKBACK_DAYS - Days to look back for metrics (default: 30)
# AZURE_DISCOUNT_PERCENTAGE - Discount percentage off MSRP (optional, defaults to 0)
# SCAN_MODE - Performance mode: full (default), quick, sample
# MAX_PARALLEL_JOBS - Maximum parallel metrics collection jobs (default: 10)

# Configuration
LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS:-30}
REPORT_FILE="vm_optimization_report.txt"
ISSUES_FILE="vm_optimization_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/vm_optimization_issues_$$.json"
SMALL_SAVINGS_TMP="$TEMP_DIR/vm_small_savings_$$.tmp"
SUBSCRIPTION_SUMMARY_TMP="$TEMP_DIR/vm_subscription_summary_$$.tmp"

# Cost thresholds for severity classification
LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD:-500}
MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD:-2000}
HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD:-10000}

# Discount percentage (default to 0 if not set)
DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE:-0}

# Utilization thresholds
CPU_UNDERUTILIZATION_THRESHOLD=30     # CPU < 30% = oversized
CPU_OVERUTILIZATION_THRESHOLD=85      # CPU > 85% = undersized
MEMORY_UNDERUTILIZATION_THRESHOLD=40  # Memory < 40% = oversized
MEMORY_OVERUTILIZATION_THRESHOLD=90   # Memory > 90% = undersized

# Initialize outputs
echo -n "[" > "$ISSUES_TMP"
first_issue=true
echo "0" > "$SMALL_SAVINGS_TMP"  # Track count of small savings opportunities
echo "0.00" >> "$SMALL_SAVINGS_TMP"  # Track total amount of small savings
: > "$SUBSCRIPTION_SUMMARY_TMP"  # Track per-subscription summaries

# Cleanup function
cleanup() {
    if [[ ! -f "$ISSUES_FILE" ]] || [[ ! -s "$ISSUES_FILE" ]]; then
        echo '[]' > "$ISSUES_FILE"
    fi
    rm -f "$ISSUES_TMP" "$SMALL_SAVINGS_TMP" "${SMALL_SAVINGS_TMP}.lock" "$SUBSCRIPTION_SUMMARY_TMP" 2>/dev/null || true
    # Clean up performance utilities
    azure_perf_cleanup 2>/dev/null || true
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

# Azure VM Pricing Database (same as other scripts)
get_azure_vm_cost() {
    local vm_size="$1"
    local vm_lower=$(echo "$vm_size" | tr '[:upper:]' '[:lower:]')
    
    case "$vm_lower" in
        # D-series v3
        standard_d2s_v3) echo "70.08" ;;
        standard_d4s_v3) echo "140.16" ;;
        standard_d8s_v3) echo "280.32" ;;
        standard_d16s_v3) echo "560.64" ;;
        standard_d32s_v3) echo "1121.28" ;;
        
        # D-series v5
        standard_d2s_v5) echo "69.35" ;;
        standard_d4s_v5) echo "138.70" ;;
        standard_d8s_v5) echo "277.40" ;;
        standard_d16s_v5) echo "554.80" ;;
        standard_d32s_v5) echo "1109.60" ;;
        
        # E-series v3
        standard_e2s_v3) echo "132.41" ;;
        standard_e4s_v3) echo "264.82" ;;
        standard_e8s_v3) echo "529.64" ;;
        standard_e16s_v3) echo "1059.28" ;;
        standard_e32s_v3) echo "2118.56" ;;
        
        # E-series v4
        standard_e8ds_v4) echo "467.20" ;;
        standard_e16ds_v4) echo "934.40" ;;
        standard_e32ds_v4) echo "1868.80" ;;
        
        # E-series v5
        standard_e8ds_v5) echo "584.00" ;;
        standard_e16ds_v5) echo "1168.00" ;;
        standard_e32ds_v5) echo "2336.00" ;;
        
        # D-series v5 (more)
        standard_d16ds_v5) echo "554.80" ;;
        
        # F-series v2
        standard_f2s_v2) echo "59.13" ;;
        standard_f4s_v2) echo "118.26" ;;
        standard_f8s_v2) echo "236.52" ;;
        standard_f16s_v2) echo "473.04" ;;
        standard_f32s_v2) echo "946.08" ;;
        
        # B-series (Burstable)
        standard_b1s) echo "7.59" ;;
        standard_b2s) echo "30.37" ;;
        standard_b2ms) echo "60.74" ;;
        standard_b4ms) echo "121.47" ;;
        standard_b8ms) echo "242.93" ;;
        standard_b12ms) echo "364.40" ;;
        standard_b16ms) echo "485.86" ;;
        standard_b20ms) echo "607.33" ;;
        
        # Default fallback
        *) echo "140.16" ;;
    esac
}

# Apply discount to cost
apply_discount() {
    local cost="$1"
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        local discount_factor=$(echo "scale=4; 1 - ($DISCOUNT_PERCENTAGE / 100)" | bc -l)
        echo "scale=2; $cost * $discount_factor" | bc -l
    else
        echo "$cost"
    fi
}

# Get VM specs
get_vm_specs() {
    local vm_size="$1"
    local vm_lower=$(echo "$vm_size" | tr '[:upper:]' '[:lower:]')
    
    case "$vm_lower" in
        standard_d2*|standard_e2*|standard_f2*|standard_b2*) echo "2 8" ;;
        standard_d4*|standard_e4*|standard_f4*|standard_b4*) echo "4 16" ;;
        standard_d8*|standard_e8*|standard_f8*|standard_b8*) echo "8 32" ;;
        standard_b12*) echo "12 48" ;;
        standard_d16*|standard_e16*|standard_f16*|standard_b16*) echo "16 64" ;;
        standard_b20*) echo "20 80" ;;
        standard_d32*|standard_e32*|standard_f32*) echo "32 128" ;;
        standard_d48*|standard_e48*|standard_f48*) echo "48 192" ;;
        standard_d64*|standard_e64*|standard_f64*) echo "64 256" ;;
        standard_b1*) echo "1 1" ;;
        *) echo "4 16" ;;
    esac
}

# Determine severity based on monthly savings
get_severity_for_savings() {
    local monthly_savings="$1"
    local savings_int=$(printf "%.0f" "$monthly_savings")
    
    if (( savings_int >= HIGH_COST_THRESHOLD )); then
        echo "2"
    elif (( savings_int >= MEDIUM_COST_THRESHOLD )); then
        echo "3"
    elif (( savings_int >= LOW_COST_THRESHOLD )); then
        echo "4"
    else
        echo "4"
    fi
}

# Get CPU and Memory metrics from Azure Monitor
get_vm_utilization_metrics() {
    local vm_id="$1"
    local lookback_days="$2"
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$lookback_days days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    # Get CPU metrics
    local cpu_data=$(az monitor metrics list \
        --resource "$vm_id" \
        --metric "Percentage CPU" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average Maximum \
        -o json 2>/dev/null || echo '{"value":[]}')
    
    local avg_cpu=$(echo "$cpu_data" | jq -r '.value[0].timeseries[0].data[] | select(.average != null) | .average' | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print "0"}')
    local max_cpu=$(echo "$cpu_data" | jq -r '.value[0].timeseries[0].data[] | select(.maximum != null) | .maximum' | jq -s 'max // 0')
    
    [[ -z "$avg_cpu" || "$avg_cpu" == "null" ]] && avg_cpu="0"
    [[ -z "$max_cpu" || "$max_cpu" == "null" ]] && max_cpu="0"
    
    # Get Memory metrics (Available Memory Bytes)
    # NOTE: This metric requires Azure Monitor Agent (AMA) or VM Insights to be enabled
    # Without the agent, memory metrics will not be available (this is expected)
    local memory_data=$(az monitor metrics list \
        --resource "$vm_id" \
        --metric "Available Memory Bytes" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average Minimum \
        -o json 2>/dev/null || echo '{"value":[]}')
    
    # Get VM size to calculate total memory
    local vm_size=$(az vm show --ids "$vm_id" --query "hardwareProfile.vmSize" -o tsv 2>/dev/null)
    local vm_specs=$(get_vm_specs "$vm_size")
    local total_memory_gb=$(echo "$vm_specs" | awk '{print $2}')
    
    # Validate total_memory_gb is a number
    [[ -z "$total_memory_gb" || ! "$total_memory_gb" =~ ^[0-9]+$ ]] && total_memory_gb="16"
    
    local total_memory_bytes=$(echo "scale=0; $total_memory_gb * 1024 * 1024 * 1024" | bc -l 2>/dev/null || echo "0")
    
    # Calculate memory usage percentage (100 - (available/total * 100))
    local avg_available=$(echo "$memory_data" | jq -r '.value[0].timeseries[0].data[] | select(.average != null) | .average' | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print "0"}')
    local min_available=$(echo "$memory_data" | jq -r '.value[0].timeseries[0].data[] | select(.minimum != null) | .minimum' | jq -s 'min // 0')
    
    # Validate numeric values - default to 0 if empty or non-numeric
    [[ -z "$avg_available" || "$avg_available" == "null" ]] && avg_available="0"
    [[ -z "$min_available" || "$min_available" == "null" ]] && min_available="0"
    
    local avg_memory="0"
    local max_memory="0"
    
    # Only calculate if we have valid non-zero values
    if [[ "$total_memory_bytes" != "0" && "$avg_available" != "0" && "$avg_available" =~ ^[0-9.]+$ ]]; then
        avg_memory=$(echo "scale=2; 100 - ($avg_available / $total_memory_bytes * 100)" | bc -l 2>/dev/null || echo "0")
        max_memory=$(echo "scale=2; 100 - ($min_available / $total_memory_bytes * 100)" | bc -l 2>/dev/null || echo "0")
    fi
    
    [[ -z "$avg_memory" || "$avg_memory" == "null" ]] && avg_memory="0"
    [[ -z "$max_memory" || "$max_memory" == "null" ]] && max_memory="0"
    
    # Return format: avg_cpu|max_cpu|avg_memory|max_memory
    echo "${avg_cpu}|${max_cpu}|${avg_memory}|${max_memory}"
}

# Main execution
main() {
    # Initialize performance utilities
    azure_perf_init "$TEMP_DIR" 2>/dev/null || true
    print_scan_mode_info 2>/dev/null || true
    
    printf "Azure Virtual Machine Optimization Analysis — %s\n" "$(date -Iseconds)" > "$REPORT_FILE"
    printf "Analysis Period: Past %s days\n" "$LOOKBACK_DAYS" >> "$REPORT_FILE"
    printf "Scan Mode: %s\n" "${SCAN_MODE:-full}" >> "$REPORT_FILE"
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        printf "Discount Applied: %s%% off MSRP\n" "$DISCOUNT_PERCENTAGE" >> "$REPORT_FILE"
    fi
    hr
    
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   Azure Virtual Machine Optimization Analysis                    ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    progress "🚀 Starting VM optimization analysis at $(date '+%Y-%m-%d %H:%M:%S')"
    progress ""
    
    # Parse subscription IDs
    if [[ -z "${AZURE_SUBSCRIPTION_IDS:-}" ]]; then
        AZURE_SUBSCRIPTION_IDS=$(az account show --query "id" -o tsv)
        progress "No subscription IDs specified. Using current subscription: $AZURE_SUBSCRIPTION_IDS"
    fi
    
    IFS=',' read -ra SUBSCRIPTIONS <<< "$AZURE_SUBSCRIPTION_IDS"
    local total_subscriptions=${#SUBSCRIPTIONS[@]}
    progress "Analyzing $total_subscriptions subscription(s)..."
    
    # Parse resource groups filter (if specified)
    local -a RESOURCE_GROUP_FILTER=()
    if [[ -n "${AZURE_RESOURCE_GROUPS:-}" ]]; then
        IFS=',' read -ra RESOURCE_GROUP_FILTER <<< "$AZURE_RESOURCE_GROUPS"
        # Trim whitespace from each element
        for i in "${!RESOURCE_GROUP_FILTER[@]}"; do
            RESOURCE_GROUP_FILTER[$i]=$(echo "${RESOURCE_GROUP_FILTER[$i]}" | xargs)
        done
        progress "Filtering to resource group(s): ${RESOURCE_GROUP_FILTER[*]}"
    else
        progress "No resource group filter specified - analyzing all resource groups"
    fi
    
    # Analyze each subscription
    for subscription_id in "${SUBSCRIPTIONS[@]}"; do
        subscription_id=$(echo "$subscription_id" | xargs)
        
        progress ""
        progress "═══════════════════════════════════════════════════════════════════"
        progress "Subscription: $subscription_id"
        progress "═══════════════════════════════════════════════════════════════════"
        
        # Set subscription context
        az account set --subscription "$subscription_id" 2>/dev/null || {
            log "❌ Failed to set subscription context for: $subscription_id"
            continue
        }
        
        local subscription_name=$(az account show --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null || echo "Unknown")
        log "Analyzing Subscription: $subscription_name ($subscription_id)"
        hr
        
        # Get VMs in subscription (filtered by resource group if specified)
        progress "Fetching VMs..."
        local vms
        if [[ ${#RESOURCE_GROUP_FILTER[@]} -gt 0 ]]; then
            # Resource group filter is specified - fetch only VMs in those resource groups
            if is_resource_graph_available 2>/dev/null; then
                # Build Resource Graph filter for resource groups (case-insensitive)
                local rg_filter_parts=()
                for rg in "${RESOURCE_GROUP_FILTER[@]}"; do
                    rg_filter_parts+=("'$rg'")
                done
                local rg_filter_str=$(IFS=','; echo "${rg_filter_parts[*]}")
                local rg_graph_filter="resourceGroup in~ (${rg_filter_str})"
                local graph_result=$(query_vms_graph "$subscription_id" "$rg_graph_filter")
                vms=$(echo "$graph_result" | jq '[.data[] | {
                    name: .name,
                    id: .id,
                    location: .location,
                    resourceGroup: .resourceGroup,
                    hardwareProfile: {vmSize: .vmSize},
                    _powerState: .powerState
                }]')
            else
                # Fetch VMs from each specified resource group using az CLI
                vms="[]"
                for rg in "${RESOURCE_GROUP_FILTER[@]}"; do
                    progress "  Fetching VMs from resource group: $rg"
                    local rg_vms=$(az vm list --subscription "$subscription_id" --resource-group "$rg" -o json 2>/dev/null || echo '[]')
                    vms=$(echo "$vms" "$rg_vms" | jq -s '.[0] + .[1]')
                done
            fi
        else
            # No resource group filter - fetch all VMs in the subscription
            if is_resource_graph_available 2>/dev/null; then
                local graph_result=$(query_vms_graph "$subscription_id")
                vms=$(echo "$graph_result" | jq '[.data[] | {
                    name: .name,
                    id: .id,
                    location: .location,
                    resourceGroup: .resourceGroup,
                    hardwareProfile: {vmSize: .vmSize},
                    _powerState: .powerState
                }]')
            else
                vms=$(az vm list --subscription "$subscription_id" -o json 2>/dev/null || echo '[]')
            fi
        fi
        local vm_count=$(echo "$vms" | jq 'length')
        
        progress "✓ Found $vm_count VM(s)"
        log "Total VMs Found: $vm_count"
        
        if [[ "$vm_count" -eq 0 ]]; then
            log "ℹ️  No VMs found in this subscription"
            hr
            continue
        fi
        
        progress "Note: Databricks and AKS-managed VMs will be skipped (optimize via cluster/node pool config)"
        
        # Analyze each VM
        local analyzed_count=0
        local skipped_count=0
        
        while IFS= read -r vm_data; do
            local vm_name=$(echo "$vm_data" | jq -r '.name')
            local vm_id=$(echo "$vm_data" | jq -r '.id')
            local vm_location=$(echo "$vm_data" | jq -r '.location')
            local vm_size=$(echo "$vm_data" | jq -r '.hardwareProfile.vmSize')
            local resource_group=$(echo "$vm_data" | jq -r '.resourceGroup')
            local os_type=$(echo "$vm_data" | jq -r '.storageProfile.osDisk.osType // "Unknown"')
            
            # SKIP Databricks-managed VMs (these should be optimized through Databricks cluster config)
            if [[ "$resource_group" =~ [Dd][Aa][Tt][Aa][Bb][Rr][Ii][Cc][Kk][Ss] ]]; then
                progress "⏭️  Skipping Databricks-managed VM: $vm_name (managed by Databricks clusters)"
                skipped_count=$((skipped_count + 1))
                continue
            fi
            
            # SKIP AKS-managed VMs (these should be optimized through AKS node pools)
            if [[ "$resource_group" =~ MC_ ]] || [[ "$vm_name" =~ aks-.*-[0-9]+ ]]; then
                progress "⏭️  Skipping AKS-managed VM: $vm_name (managed by AKS node pools)"
                skipped_count=$((skipped_count + 1))
                continue
            fi
            
            analyzed_count=$((analyzed_count + 1))
            progress ""
            progress "Analyzing VM: $vm_name"
            log ""
            log "VM: $vm_name"
            log "  Resource Group: $resource_group"
            log "  Location: $vm_location"
            log "  Size: $vm_size"
            log "  OS: $os_type"
            
            # Get VM power state
            local power_state=$(az vm get-instance-view --ids "$vm_id" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" -o tsv 2>/dev/null)
            log "  Power State: $power_state"
            
            # Calculate costs
            local monthly_cost=$(get_azure_vm_cost "$vm_size")
            monthly_cost=$(apply_discount "$monthly_cost")
            log "  Monthly Cost: \$$monthly_cost"
            
            # === ANALYSIS 1: STOPPED BUT NOT DEALLOCATED VMs ===
            if [[ "$power_state" == "VM stopped" ]]; then
                progress "  ⚠️  VM is stopped but NOT deallocated - still incurring costs!"
                
                local severity=$(get_severity_for_savings "$monthly_cost")
                local annual_cost=$(echo "scale=2; $monthly_cost * 12" | bc -l)
                
                local details="VM STOPPED BUT NOT DEALLOCATED - WASTING COSTS:

VM: $vm_name
Resource Group: $resource_group
Location: $vm_location
Subscription: $subscription_name ($subscription_id)

ISSUE:
This VM is in 'Stopped' state but NOT deallocated. This means:
- Compute resources are still reserved
- You're paying full VM compute costs
- The VM is just powered off, not released

CURRENT COST:
- VM Size: $vm_size
- Monthly Waste: \$$monthly_cost
- Annual Waste: \$$annual_cost

RECOMMENDATION:
Deallocate the VM to stop compute charges. You'll only pay for storage.

IMPORTANT:
- 'Stop' (from VM) = Still paying compute costs
- 'Stop (deallocate)' (from Portal) = Only pay storage costs
- Difference: \$$monthly_cost/month savings"

                local next_steps="IMMEDIATE ACTION - Deallocate the VM:

Azure Portal:
1. Go to VM: $vm_name
2. Click 'Stop' button (this deallocates by default in Portal)
3. Confirm deallocation

Azure CLI:
az vm deallocate --name '$vm_name' --resource-group '$resource_group' --subscription '$subscription_id'

Alternative - Delete if no longer needed:
az vm delete --name '$vm_name' --resource-group '$resource_group' --subscription '$subscription_id' --yes

Note: Deallocation releases compute resources but keeps disks. VM can be restarted later."

                add_issue "VM: $vm_name - Stopped but Not Deallocated (\$$monthly_cost/month waste)" "$details" "$severity" "$next_steps"
            fi
            
            # === ANALYSIS 2: OVERSIZED VMs (LOW UTILIZATION) ===
            if [[ "$power_state" == "VM running" ]]; then
                progress "  Checking utilization metrics..."
                
                local utilization_metrics=$(get_vm_utilization_metrics "$vm_id" "$LOOKBACK_DAYS")
                IFS='|' read -r avg_cpu max_cpu avg_memory max_memory <<< "$utilization_metrics"
                
                # Validate metrics are numeric, default to 0 if not
                [[ -z "$avg_cpu" || ! "$avg_cpu" =~ ^[0-9.]+$ ]] && avg_cpu="0"
                [[ -z "$max_cpu" || ! "$max_cpu" =~ ^[0-9.]+$ ]] && max_cpu="0"
                [[ -z "$avg_memory" || ! "$avg_memory" =~ ^[0-9.]+$ ]] && avg_memory="0"
                [[ -z "$max_memory" || ! "$max_memory" =~ ^[0-9.]+$ ]] && max_memory="0"
                
                log "  Average CPU: ${avg_cpu}%"
                log "  Peak CPU: ${max_cpu}%"
                log "  Average Memory: ${avg_memory}%"
                log "  Peak Memory: ${max_memory}%"
                
                # Check if memory metrics are available
                local memory_available=true
                if [[ "$max_memory" == "0" || "$avg_memory" == "0" ]]; then
                    memory_available=false
                    log "  ⚠️  Memory metrics unavailable - Azure Monitor Agent (AMA) or VM Insights required"
                    log "     To enable: Install Azure Monitor Agent or enable VM Insights in Azure Portal"
                    log "     Proceeding with CPU-only analysis..."
                    progress "  ℹ️  Memory metrics unavailable - using CPU-only analysis"
                fi
                
                # Check if VM is underutilized
                # If memory metrics available: require BOTH CPU and Memory to be underutilized
                # If memory metrics unavailable: use CPU-only with a warning flag
                local is_underutilized=false
                local analysis_type=""
                
                if [[ "$memory_available" == "true" ]]; then
                    # Full analysis with both CPU and Memory
                    if (( $(echo "$max_cpu > 0 && $max_cpu < $CPU_UNDERUTILIZATION_THRESHOLD" | bc -l 2>/dev/null || echo "0") )) && \
                       (( $(echo "$max_memory > 0 && $max_memory < $MEMORY_UNDERUTILIZATION_THRESHOLD" | bc -l 2>/dev/null || echo "0") )); then
                        is_underutilized=true
                        analysis_type="CPU+Memory"
                    fi
                else
                    # CPU-only analysis (memory unavailable)
                    # Use a more conservative threshold for CPU-only (20% instead of 30%)
                    local cpu_only_threshold=20
                    if (( $(echo "$max_cpu > 0 && $max_cpu < $cpu_only_threshold" | bc -l 2>/dev/null || echo "0") )); then
                        is_underutilized=true
                        analysis_type="CPU-only"
                    fi
                fi
                
                if [[ "$is_underutilized" == "true" ]]; then
                    if [[ "$analysis_type" == "CPU-only" ]]; then
                        progress "  ⚠️  VM is underutilized [${analysis_type}] (peak CPU: ${max_cpu}%)"
                    else
                        progress "  ⚠️  VM is underutilized [${analysis_type}] (peak CPU: ${max_cpu}%, peak Memory: ${max_memory}%)"
                    fi
                    
                    # Suggest smaller VM size
                    local specs=$(get_vm_specs "$vm_size")
                    local current_vcpus=$(echo "$specs" | awk '{print $1}')
                    
                    # Suggest B-series for low utilization VMs
                    local suggested_vm=""
                    local suggested_cost=""
                    
                    if [[ $current_vcpus -le 2 ]]; then
                        suggested_vm="Standard_B2s"
                        suggested_cost=$(get_azure_vm_cost "$suggested_vm")
                    elif [[ $current_vcpus -le 4 ]]; then
                        suggested_vm="Standard_B2ms"
                        suggested_cost=$(get_azure_vm_cost "$suggested_vm")
                    elif [[ $current_vcpus -le 8 ]]; then
                        suggested_vm="Standard_B4ms"
                        suggested_cost=$(get_azure_vm_cost "$suggested_vm")
                    elif [[ $current_vcpus -le 12 ]]; then
                        suggested_vm="Standard_B8ms"
                        suggested_cost=$(get_azure_vm_cost "$suggested_vm")
                    elif [[ $current_vcpus -le 16 ]]; then
                        suggested_vm="Standard_B12ms"
                        suggested_cost=$(get_azure_vm_cost "$suggested_vm")
                    elif [[ $current_vcpus -le 20 ]]; then
                        suggested_vm="Standard_B16ms"
                        suggested_cost=$(get_azure_vm_cost "$suggested_vm")
                    else
                        # For very large VMs (>20 vCPUs), suggest B20ms
                        suggested_vm="Standard_B20ms"
                        suggested_cost=$(get_azure_vm_cost "$suggested_vm")
                    fi
                    
                    if [[ -n "$suggested_vm" ]]; then
                        suggested_cost=$(apply_discount "$suggested_cost")
                        local savings=$(echo "scale=2; $monthly_cost - $suggested_cost" | bc -l)
                        
                        # Only report if savings are significant (>$50/month)
                        if (( $(echo "$savings > 50" | bc -l) )); then
                            local annual_savings=$(echo "scale=2; $savings * 12" | bc -l)
                            local severity=$(get_severity_for_savings "$savings")
                            
                            local utilization_section=""
                            local rationale_section=""
                            
                            if [[ "$analysis_type" == "CPU-only" ]]; then
                                utilization_section="UTILIZATION ANALYSIS (${LOOKBACK_DAYS} days) [CPU-ONLY]:
- Average CPU: ${avg_cpu}%
- Peak CPU: ${max_cpu}% (threshold: 20% for CPU-only)
- Memory: ⚠️  Not available (Azure Monitor Agent required)

NOTE: This recommendation is based on CPU metrics only.
Memory metrics require Azure Monitor Agent or VM Insights to be enabled.
Please verify memory utilization manually before resizing."
                                rationale_section="CPU utilization (peak: ${max_cpu}%) is well below the conservative 20% threshold.
⚠️  CAUTION: Memory utilization was not analyzed. Verify memory is not constrained before resizing.
B-series VMs provide burst capacity for occasional spikes while saving costs."
                            else
                                utilization_section="UTILIZATION ANALYSIS (${LOOKBACK_DAYS} days):
- Average CPU: ${avg_cpu}%
- Peak CPU: ${max_cpu}% (threshold: ${CPU_UNDERUTILIZATION_THRESHOLD}%)
- Average Memory: ${avg_memory}%
- Peak Memory: ${max_memory}% (threshold: ${MEMORY_UNDERUTILIZATION_THRESHOLD}%)"
                                rationale_section="Both CPU (peak: ${max_cpu}%) and Memory (peak: ${max_memory}%) are well below thresholds.
B-series VMs provide burst capacity for occasional spikes while saving costs."
                            fi
                            
                            local details="VM OVERSIZED - LOW UTILIZATION:

VM: $vm_name
Resource Group: $resource_group
Location: $vm_location
Subscription: $subscription_name ($subscription_id)

CURRENT CONFIGURATION:
- VM Size: $vm_size
- vCPUs: $current_vcpus
- Monthly Cost: \$$monthly_cost

${utilization_section}

RECOMMENDATION:
Switch to $suggested_vm (Burstable B-series)
- Monthly Cost: \$$suggested_cost
- Burstable performance suitable for low-utilization workloads
- Can burst to 100% CPU when needed

PROJECTED SAVINGS:
- Monthly Savings: \$$savings
- Annual Savings: \$$annual_savings

RATIONALE:
${rationale_section}"

                            local next_steps="1. Verify workload patterns over full week including business hours
2. Test in dev/test environment first
3. Resize VM to $suggested_vm:

Azure Portal:
1. Go to VM: $vm_name
2. Click 'Size' in left menu
3. Select '$suggested_vm'
4. Click 'Resize'

Azure CLI:
az vm resize --name '$vm_name' --resource-group '$resource_group' --size '$suggested_vm' --subscription '$subscription_id'

Note: Resizing requires VM restart. Plan maintenance window."

                            add_issue "VM: $vm_name - Oversized, Low Utilization (\$$savings/month)" "$details" "$severity" "$next_steps"
                        else
                            # Track small savings (filtered out as < $50/month)
                            if (( $(echo "$savings > 0" | bc -l) )); then
                                progress "  ℹ️  Small savings opportunity: \$$savings/month (below \$50 threshold)"
                                # Atomically increment counters using lock file
                                (
                                    flock -x 200
                                    local count=$(head -n1 "$SMALL_SAVINGS_TMP")
                                    local total=$(tail -n1 "$SMALL_SAVINGS_TMP")
                                    count=$((count + 1))
                                    total=$(echo "scale=2; $total + $savings" | bc -l)
                                    echo "$count" > "$SMALL_SAVINGS_TMP"
                                    echo "$total" >> "$SMALL_SAVINGS_TMP"
                                ) 200>"${SMALL_SAVINGS_TMP}.lock"
                            fi
                        fi
                    fi
                fi
            fi
            
            log ""
        done < <(echo "$vms" | jq -c '.[]')
        
        log ""
        log "Subscription Summary:"
        log "  Total VMs: $vm_count"
        log "  Analyzed: $analyzed_count"
        log "  Skipped (Databricks/AKS-managed): $skipped_count"
        
        # Save subscription info for later summary calculation
        echo "${subscription_name}|${subscription_id}" >> "$SUBSCRIPTION_SUMMARY_TMP"
        
        hr
    done
    
    # Finalize issues JSON
    echo "]" >> "$ISSUES_TMP"
    mv "$ISSUES_TMP" "$ISSUES_FILE"
    
    # Generate summary
    local issue_count=$(jq 'length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    local total_savings=$(jq -r '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount | gsub(","; "") | tonumber] | add // 0' "$ISSUES_FILE" 2>/dev/null || echo "0")
    
    log ""
    log "╔════════════════════════════════════════════════════════════════════╗"
    log "║   ANALYSIS COMPLETE                                                ║"
    log "╚════════════════════════════════════════════════════════════════════╝"
    log ""
    log "Total Issues Found: $issue_count"
    
    if [[ "$issue_count" -gt 0 ]]; then
        log "Total Potential Monthly Savings: \$$total_savings"
        local annual_savings=$(echo "scale=2; $total_savings * 12" | bc -l 2>/dev/null || echo "0")
        log "Total Potential Annual Savings: \$$annual_savings"
        
        # Add opportunity breakdown by size
        local high_opportunities=$(jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. >= 100)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
        local medium_opportunities=$(jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. >= 50 and . < 100)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
        local low_opportunities=$(jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. > 0 and . < 50)] | length' "$ISSUES_FILE" 2>/dev/null || echo "0")
        
        local high_savings=$(jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. >= 100)] | add // 0' "$ISSUES_FILE" 2>/dev/null || echo "0")
        local medium_savings=$(jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. >= 50 and . < 100)] | add // 0' "$ISSUES_FILE" 2>/dev/null || echo "0")
        local low_savings=$(jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. > 0 and . < 50)] | add // 0' "$ISSUES_FILE" 2>/dev/null || echo "0")
        
        log ""
        log "EFFORT vs IMPACT ANALYSIS:"
        log "  🔥 HIGH IMPACT (>\$100/month each):    $high_opportunities issues = \$$high_savings/month total"
        log "  ⚡ MEDIUM IMPACT (\$50-100/month):     $medium_opportunities issues = \$$medium_savings/month total"
        log "  ⭐ LOW IMPACT (<\$50/month each):      $low_opportunities issues = \$$low_savings/month total"
        log ""
        if [[ $high_opportunities -gt 0 ]]; then
            local high_percentage=$(echo "scale=0; ($high_savings / $total_savings) * 100" | bc -l 2>/dev/null || echo "0")
            log "💡 RECOMMENDATION: Focus on the $high_opportunities HIGH IMPACT opportunities first!"
            log "   These represent ${high_percentage}% of total savings with minimal effort."
        elif [[ $medium_opportunities -gt 5 ]]; then
            log "💡 RECOMMENDATION: Focus on MEDIUM IMPACT opportunities - good ROI on effort."
        else
            log "💡 RECOMMENDATION: Consider automating LOW IMPACT adjustments in bulk for efficiency."
        fi
        
        # Show top 5 high-value opportunities
        local top_opportunities=$(jq -r '[.[] | {title: .title, amount: (.title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber)}] | sort_by(.amount) | reverse | limit(5; .[]) | .title' "$ISSUES_FILE" 2>/dev/null)
        if [[ -n "$top_opportunities" ]]; then
            log ""
            log "TOP 5 OPPORTUNITIES (by savings):"
            while IFS= read -r line; do
                log "  • $line"
            done <<< "$top_opportunities"
        fi
        
        # Add breakdown by subscription with prioritization guidance
        if [[ -f "$SUBSCRIPTION_SUMMARY_TMP" ]] && [[ -s "$SUBSCRIPTION_SUMMARY_TMP" ]]; then
            log ""
            log "════════════════════════════════════════════════════════════════════"
            log "SAVINGS BY SUBSCRIPTION (Prioritized by Impact)"
            log "════════════════════════════════════════════════════════════════════"
            log ""
            printf "%-35s %6s %6s %6s  %15s  %s\n" "SUBSCRIPTION" "HIGH" "MEDIUM" "LOW" "MONTHLY SAVINGS" "PRIORITY" >> "$REPORT_FILE"
            printf "%-35s %6s %6s %6s  %15s  %s\n" "───────────────────────────────────" "──────" "──────" "──────" "───────────────" "────────" >> "$REPORT_FILE"
            
            # Store subscription data for sorting by high-impact issues
            declare -a sub_data
            while IFS='|' read -r sub_name sub_id; do
                # Get all issues for this subscription
                local sub_issues=$(jq --arg sub_id "$sub_id" '[.[] | select(.details | contains($sub_id))]' "$ISSUES_FILE" 2>/dev/null || echo '[]')
                
                # Count issues by savings size (HIGH: >$100, MEDIUM: $50-100, LOW: <$50)
                local high_count=$(echo "$sub_issues" | jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. >= 100)] | length' 2>/dev/null || echo "0")
                local medium_count=$(echo "$sub_issues" | jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. >= 50 and . < 100)] | length' 2>/dev/null || echo "0")
                local low_count=$(echo "$sub_issues" | jq '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber | select(. > 0 and . < 50)] | length' 2>/dev/null || echo "0")
                
                local sub_savings=$(echo "$sub_issues" | jq -r '[.[] | .title | capture("\\$(?<amount>[0-9,]+\\.?[0-9]*)/month").amount // "0" | gsub(","; "") | tonumber] | add // 0' 2>/dev/null || echo "0")
                
                # Determine priority based on high-impact opportunities
                local priority="⭐ LOW"
                if [[ $high_count -ge 5 ]]; then
                    priority="🔥 HIGH"
                elif [[ $high_count -ge 2 ]]; then
                    priority="⚡ MEDIUM"
                elif [[ $medium_count -ge 5 ]]; then
                    priority="⚡ MEDIUM"
                fi
                
                # Store for sorting (format: high_count|sub_name|sub_id|high|medium|low|savings|priority)
                sub_data+=("$high_count|$sub_name|$sub_id|$high_count|$medium_count|$low_count|$sub_savings|$priority")
            done < "$SUBSCRIPTION_SUMMARY_TMP"
            
            # Sort by high-impact count (descending) and print
            while IFS= read -r entry; do
                IFS='|' read -r sort_key sub_name sub_id high_count medium_count low_count sub_savings priority <<< "$entry"
                
                # Truncate subscription name if too long
                local display_name="$sub_name"
                if [[ ${#display_name} -gt 33 ]]; then
                    display_name="${display_name:0:30}..."
                fi
                
                printf "%-35s %6d %6d %6d  \$%14.2f  %s\n" "$display_name" "$high_count" "$medium_count" "$low_count" "$sub_savings" "$priority" >> "$REPORT_FILE"
            done < <(printf '%s\n' "${sub_data[@]}" | sort -t'|' -k1 -nr)
            
            log ""
            log "Impact Levels:"
            log "  HIGH:   Savings >\$100/month each (focus here first for maximum ROI!)"
            log "  MEDIUM: Savings \$50-100/month each (good balance of effort vs savings)"
            log "  LOW:    Savings <\$50/month each (consider bulk automation or defer)"
            log ""
            log "════════════════════════════════════════════════════════════════════"
        fi
    else
        log ""
        log "✅ No VM optimization opportunities found!"
        log "   All standalone VMs appear to be properly managed."
    fi
    
    # Add summary of small savings opportunities (< $50/month)
    if [[ -f "$SMALL_SAVINGS_TMP" ]]; then
        local small_count=$(head -n1 "$SMALL_SAVINGS_TMP" 2>/dev/null || echo "0")
        local small_total=$(tail -n1 "$SMALL_SAVINGS_TMP" 2>/dev/null || echo "0.00")
        
        if [[ "$small_count" -gt 0 ]] && (( $(echo "$small_total > 0" | bc -l) )); then
            log ""
            log "ℹ️  Additional Opportunities (below \$50/month threshold):"
            log "   Micro-optimization potential: \$$small_total/month across $small_count VMs"
            log "   (These represent valid but small cost savings - consider if effort is worthwhile)"
            progress ""
            progress "ℹ️  Found $small_count additional micro-optimization opportunities totaling \$$small_total/month"
        fi
    fi
    
    log ""
    log "Analysis completed at $(date -Iseconds)"
    log "Report saved to: $REPORT_FILE"
    log "Issues JSON saved to: $ISSUES_FILE"
    
    progress ""
    progress "✅ Analysis complete!"
    progress "   Issues found: $issue_count"
    if [[ "$issue_count" -gt 0 ]]; then
        progress "   Potential monthly savings: \$$total_savings"
    fi
}

# Run main function
main "$@"

