#!/bin/bash

# Azure Virtual Machine Optimization Analysis Script
# Analyzes VMs to identify cost optimization opportunities
# Focuses on: 1) Stopped-not-deallocated VMs, 2) Oversized/undersized VMs, 3) Reserved Instance opportunities

set -eo pipefail

# Environment variables expected:
# AZURE_SUBSCRIPTION_IDS - Comma-separated list of subscription IDs to analyze (required)
# AZURE_RESOURCE_GROUPS - Comma-separated list of resource groups to analyze (optional, defaults to all)
# COST_ANALYSIS_LOOKBACK_DAYS - Days to look back for metrics (default: 30)
# AZURE_DISCOUNT_PERCENTAGE - Discount percentage off MSRP (optional, defaults to 0)

# Configuration
LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS:-30}
REPORT_FILE="vm_optimization_report.txt"
ISSUES_FILE="vm_optimization_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/vm_optimization_issues_$$.json"

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

# Cleanup function
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
        standard_d8*|standard_e8*|standard_f8*) echo "8 32" ;;
        standard_d16*|standard_e16*|standard_f16*) echo "16 64" ;;
        standard_d32*|standard_e32*|standard_f32*) echo "32 128" ;;
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

# Get CPU metrics from Azure Monitor
get_vm_cpu_metrics() {
    local vm_id="$1"
    local lookback_days="$2"
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$lookback_days days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
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
    
    echo "${avg_cpu}|${max_cpu}"
}

# Main execution
main() {
    printf "Azure Virtual Machine Optimization Analysis — %s\n" "$(date -Iseconds)" > "$REPORT_FILE"
    printf "Analysis Period: Past %s days\n" "$LOOKBACK_DAYS" >> "$REPORT_FILE"
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
        
        # Get all VMs in subscription
        progress "Fetching VMs..."
        local vms=$(az vm list --subscription "$subscription_id" -o json 2>/dev/null || echo '[]')
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
        
        echo "$vms" | jq -c '.[]' | while read -r vm_data; do
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
                
                local cpu_metrics=$(get_vm_cpu_metrics "$vm_id" "$LOOKBACK_DAYS")
                IFS='|' read -r avg_cpu max_cpu <<< "$cpu_metrics"
                
                log "  Average CPU: ${avg_cpu}%"
                log "  Peak CPU: ${max_cpu}%"
                
                # Check if VM is underutilized
                if (( $(echo "$max_cpu > 0 && $max_cpu < $CPU_UNDERUTILIZATION_THRESHOLD" | bc -l) )); then
                    progress "  ⚠️  VM is underutilized (peak CPU: ${max_cpu}%)"
                    
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
                    fi
                    
                    if [[ -n "$suggested_vm" ]]; then
                        suggested_cost=$(apply_discount "$suggested_cost")
                        local savings=$(echo "scale=2; $monthly_cost - $suggested_cost" | bc -l)
                        
                        # Only report if savings are significant (>$50/month)
                        if (( $(echo "$savings > 50" | bc -l) )); then
                            local annual_savings=$(echo "scale=2; $savings * 12" | bc -l)
                            local severity=$(get_severity_for_savings "$savings")
                            
                            local details="VM OVERSIZED - LOW UTILIZATION:

VM: $vm_name
Resource Group: $resource_group
Location: $vm_location
Subscription: $subscription_name ($subscription_id)

CURRENT CONFIGURATION:
- VM Size: $vm_size
- vCPUs: $current_vcpus
- Monthly Cost: \$$monthly_cost

UTILIZATION ANALYSIS (${LOOKBACK_DAYS} days):
- Average CPU: ${avg_cpu}%
- Peak CPU: ${max_cpu}%
- Threshold: ${CPU_UNDERUTILIZATION_THRESHOLD}%

RECOMMENDATION:
Switch to $suggested_vm (Burstable B-series)
- Monthly Cost: \$$suggested_cost
- Burstable performance suitable for low-utilization workloads
- Can burst to 100% CPU when needed

PROJECTED SAVINGS:
- Monthly Savings: \$$savings
- Annual Savings: \$$annual_savings

RATIONALE:
Peak CPU usage is only ${max_cpu}%, well below the ${CPU_UNDERUTILIZATION_THRESHOLD}% threshold.
B-series VMs provide burst capacity for occasional spikes while saving costs."

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
                        fi
                    fi
                fi
            fi
            
            log ""
        done
        
        log ""
        log "Subscription Summary:"
        log "  Total VMs: $vm_count"
        log "  Analyzed: $analyzed_count"
        log "  Skipped (Databricks/AKS-managed): $skipped_count"
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
    else
        log ""
        log "✅ No VM optimization opportunities found!"
        log "   All standalone VMs appear to be properly managed."
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

