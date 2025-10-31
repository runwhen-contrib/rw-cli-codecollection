#!/bin/bash

# AKS Cost Optimization Analysis Script
# Analyzes 30-day utilization trends using Azure Monitor and provides cost savings recommendations
# with Azure VM pricing estimates

set -euo pipefail

# Environment variables expected:
# AKS_CLUSTER - The AKS cluster name
# AZ_RESOURCE_GROUP - The resource group containing the AKS cluster
# AZURE_RESOURCE_SUBSCRIPTION_ID - The Azure subscription ID

# Get or set subscription ID
if [[ -z "${AZURE_RESOURCE_SUBSCRIPTION_ID:-}" ]]; then
    subscription=$(az account show --query "id" -o tsv)
    echo "AZURE_RESOURCE_SUBSCRIPTION_ID is not set. Using current subscription ID: $subscription"
else
    subscription="$AZURE_RESOURCE_SUBSCRIPTION_ID"
    echo "Using specified subscription ID: $subscription"
fi

# Set the subscription to the determined ID
echo "Switching to subscription ID: $subscription"
az account set --subscription "$subscription" || { echo "Failed to set subscription."; exit 1; }

# Configuration
LOOKBACK_DAYS=30
REPORT_FILE="aks_cost_optimization_report.txt"
ISSUES_FILE="aks_cost_optimization_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/aks_cost_optimization_issues_$$.json"

# Initialize outputs
echo -n "[" > "$ISSUES_TMP"
first_issue=true

# Cleanup function
cleanup() {
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

# Azure VM Pricing Database (Pay-as-you-go pricing in USD per hour - 2024 estimates)
get_azure_vm_cost() {
    local vm_size="$1"
    case "$vm_size" in
        # Standard D-series v2
        Standard_D2s_v3)    echo "0.096" ;;
        Standard_D4s_v3)    echo "0.192" ;;
        Standard_D8s_v3)    echo "0.384" ;;
        Standard_D16s_v3)   echo "0.768" ;;
        Standard_D32s_v3)   echo "1.536" ;;
        Standard_D48s_v3)   echo "2.304" ;;
        Standard_D64s_v3)   echo "3.072" ;;
        
        # Standard D-series v4
        Standard_D2s_v4)    echo "0.096" ;;
        Standard_D4s_v4)    echo "0.192" ;;
        Standard_D8s_v4)    echo "0.384" ;;
        Standard_D16s_v4)   echo "0.768" ;;
        Standard_D32s_v4)   echo "1.536" ;;
        Standard_D48s_v4)   echo "2.304" ;;
        Standard_D64s_v4)   echo "3.072" ;;
        
        # Standard D-series v5
        Standard_D2s_v5)    echo "0.096" ;;
        Standard_D4s_v5)    echo "0.192" ;;
        Standard_D8s_v5)    echo "0.384" ;;
        Standard_D16s_v5)   echo "0.768" ;;
        Standard_D32s_v5)   echo "1.536" ;;
        Standard_D48s_v5)   echo "2.304" ;;
        Standard_D64s_v5)   echo "3.072" ;;
        Standard_D96s_v5)   echo "4.608" ;;
        
        # Standard E-series v3 (Memory optimized)
        Standard_E2s_v3)    echo "0.126" ;;
        Standard_E4s_v3)    echo "0.252" ;;
        Standard_E8s_v3)    echo "0.504" ;;
        Standard_E16s_v3)   echo "1.008" ;;
        Standard_E32s_v3)   echo "2.016" ;;
        Standard_E48s_v3)   echo "3.024" ;;
        Standard_E64s_v3)   echo "4.032" ;;
        
        # Standard E-series v4 (Memory optimized)
        Standard_E2s_v4)    echo "0.126" ;;
        Standard_E4s_v4)    echo "0.252" ;;
        Standard_E8s_v4)    echo "0.504" ;;
        Standard_E16s_v4)   echo "1.008" ;;
        Standard_E32s_v4)   echo "2.016" ;;
        Standard_E48s_v4)   echo "3.024" ;;
        Standard_E64s_v4)   echo "4.032" ;;
        
        # Standard E-series v5 (Memory optimized)
        Standard_E2s_v5)    echo "0.126" ;;
        Standard_E4s_v5)    echo "0.252" ;;
        Standard_E8s_v5)    echo "0.504" ;;
        Standard_E16s_v5)   echo "1.008" ;;
        Standard_E32s_v5)   echo "2.016" ;;
        Standard_E48s_v5)   echo "3.024" ;;
        Standard_E64s_v5)   echo "4.032" ;;
        Standard_E96s_v5)   echo "6.048" ;;
        
        # Standard F-series v2 (Compute optimized)
        Standard_F2s_v2)    echo "0.085" ;;
        Standard_F4s_v2)    echo "0.169" ;;
        Standard_F8s_v2)    echo "0.338" ;;
        Standard_F16s_v2)   echo "0.676" ;;
        Standard_F32s_v2)   echo "1.352" ;;
        Standard_F48s_v2)   echo "2.028" ;;
        Standard_F64s_v2)   echo "2.704" ;;
        Standard_F72s_v2)   echo "3.042" ;;
        
        # Standard B-series (Burstable)
        Standard_B2s)       echo "0.041" ;;
        Standard_B4ms)      echo "0.166" ;;
        Standard_B8ms)      echo "0.333" ;;
        Standard_B12ms)     echo "0.499" ;;
        Standard_B16ms)     echo "0.666" ;;
        Standard_B20ms)     echo "0.832" ;;
        
        # Large VM sizes
        Standard_D96s_v5)   echo "4.608" ;;
        Standard_E96s_v5)   echo "6.048" ;;
        Standard_M128s)     echo "11.113" ;;
        Standard_M208s_v2)  echo "23.006" ;;
        Standard_M416s_v2)  echo "46.012" ;;
        
        # Default fallback for unknown VM sizes
        *) echo "0.150" ;;
    esac
}

# Calculate time range for 30 days
end_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
start_time=$(date -u -d "$LOOKBACK_DAYS days ago" '+%Y-%m-%dT%H:%M:%SZ')

printf "AKS Cost Optimization Analysis — %s\nCluster: %s\nResource Group: %s\nSubscription: %s\nAnalysis Period: %s to %s\n" \
       "$(date -Iseconds)" "$AKS_CLUSTER" "$AZ_RESOURCE_GROUP" "$subscription" "$start_time" "$end_time" > "$REPORT_FILE"
hr

progress "Starting AKS cost optimization analysis for cluster: $AKS_CLUSTER"

# Get cluster details
progress "Fetching cluster details..."
CLUSTER_DETAILS=$(az aks show --name "$AKS_CLUSTER" --resource-group "$AZ_RESOURCE_GROUP" -o json)

if [[ -z "$CLUSTER_DETAILS" || "$CLUSTER_DETAILS" == "null" ]]; then
    log "❌ Failed to retrieve cluster details"
    echo '[]' > "$ISSUES_FILE"
    exit 1
fi

CLUSTER_ID=$(echo "$CLUSTER_DETAILS" | jq -r '.id')
NODE_RESOURCE_GROUP=$(echo "$CLUSTER_DETAILS" | jq -r '.nodeResourceGroup')

log "Cluster ID: $CLUSTER_ID"
log "Node Resource Group: $NODE_RESOURCE_GROUP"
hr

# Get node pools
progress "Analyzing node pools..."
NODE_POOLS=$(echo "$CLUSTER_DETAILS" | jq -r '.agentPoolProfiles[]')

if [[ -z "$NODE_POOLS" || "$NODE_POOLS" == "null" ]]; then
    log "❌ No node pools found"
    echo '[]' > "$ISSUES_FILE"
    exit 1
fi

# Process each node pool
echo "$CLUSTER_DETAILS" | jq -c '.agentPoolProfiles[]' | while read -r pool_data; do
    POOL_NAME=$(echo "$pool_data" | jq -r '.name')
    VM_SIZE=$(echo "$pool_data" | jq -r '.vmSize')
    NODE_COUNT=$(echo "$pool_data" | jq -r '.count')
    MIN_COUNT=$(echo "$pool_data" | jq -r '.minCount // .count')
    MAX_COUNT=$(echo "$pool_data" | jq -r '.maxCount // .count')
    AUTOSCALING_ENABLED=$(echo "$pool_data" | jq -r '.enableAutoScaling // false')
    
    log "Analyzing Node Pool: $POOL_NAME"
    log "  VM Size: $VM_SIZE"
    log "  Current Nodes: $NODE_COUNT"
    log "  Min/Max Nodes: $MIN_COUNT/$MAX_COUNT"
    log "  Autoscaling: $AUTOSCALING_ENABLED"
    
    # Get VMSS name for this node pool
    progress "Finding VMSS for node pool: $POOL_NAME"
    VMSS_LIST=$(az vmss list --resource-group "$NODE_RESOURCE_GROUP" --query "[?contains(name, '$POOL_NAME')].{name:name,id:id}" -o json)
    
    if [[ -z "$VMSS_LIST" || "$VMSS_LIST" == "[]" ]]; then
        log "  ⚠️ No VMSS found for node pool $POOL_NAME"
        continue
    fi
    
    VMSS_NAME=$(echo "$VMSS_LIST" | jq -r '.[0].name')
    VMSS_ID=$(echo "$VMSS_LIST" | jq -r '.[0].id')
    
    log "  VMSS Name: $VMSS_NAME"
    
    # Query Azure Monitor for CPU and Memory utilization over 30 days
    progress "Querying Azure Monitor for 30-day utilization trends..."
    
    # CPU utilization query (95th percentile and maximum)
    CPU_QUERY="Perf
| where TimeGenerated >= ago(${LOOKBACK_DAYS}d)
| where ObjectName == \"Processor\" and CounterName == \"% Processor Time\" and InstanceName == \"_Total\"
| where Computer has \"$POOL_NAME\"
| summarize 
    CPU_95th = percentile(CounterValue, 95),
    CPU_Max = max(CounterValue),
    CPU_Avg = avg(CounterValue),
    SampleCount = count()
| project CPU_95th, CPU_Max, CPU_Avg, SampleCount"
    
    # Memory utilization query (95th percentile and maximum)
    MEMORY_QUERY="Perf
| where TimeGenerated >= ago(${LOOKBACK_DAYS}d)
| where ObjectName == \"Memory\" and CounterName == \"% Committed Bytes In Use\"
| where Computer has \"$POOL_NAME\"
| summarize 
    Memory_95th = percentile(CounterValue, 95),
    Memory_Max = max(CounterValue),
    Memory_Avg = avg(CounterValue),
    SampleCount = count()
| project Memory_95th, Memory_Max, Memory_Avg, SampleCount"
    
    # Alternative approach using Azure Monitor metrics API for VMSS
    progress "Querying VMSS metrics for utilization data..."
    
    # Get CPU utilization metrics for the VMSS
    CPU_METRICS=$(az monitor metrics list \
        --resource "$VMSS_ID" \
        --metric "Percentage CPU" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --aggregation Average Maximum \
        --interval PT1H \
        --output json 2>/dev/null || echo '{"value":[]}')
    
    # Get memory utilization metrics (if available)
    MEMORY_METRICS=$(az monitor metrics list \
        --resource "$VMSS_ID" \
        --metric "Available Memory Bytes" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --aggregation Average Minimum \
        --interval PT1H \
        --output json 2>/dev/null || echo '{"value":[]}')
    
    # Process CPU metrics
    CPU_VALUES=$(echo "$CPU_METRICS" | jq -r '.value[0].timeseries[0].data[]?.average // empty' | grep -v '^$' || echo "")
    MEMORY_VALUES=$(echo "$MEMORY_METRICS" | jq -r '.value[0].timeseries[0].data[]?.average // empty' | grep -v '^$' || echo "")
    
    if [[ -n "$CPU_VALUES" ]]; then
        # Calculate statistics from CPU values
        CPU_STATS=$(echo "$CPU_VALUES" | awk '
        BEGIN { sum=0; count=0; max=0; values[1] }
        { 
            values[++count] = $1
            sum += $1
            if ($1 > max) max = $1
        }
        END {
            if (count > 0) {
                avg = sum/count
                # Sort for percentile calculation
                asort(values)
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
    
    # For memory, we need to calculate utilization percentage from available bytes
    # This is more complex and may require additional VM information
    # For now, we'll use a simplified approach or skip memory if not available
    MEMORY_AVG=0; MEMORY_95TH=0; MEMORY_MAX=0; MEMORY_SAMPLES=0
    
    log "  30-Day Utilization Analysis:"
    log "    CPU Average: ${CPU_AVG}%"
    log "    CPU 95th Percentile: ${CPU_95TH}%"
    log "    CPU Maximum: ${CPU_MAX}%"
    log "    Data Points: $CPU_SAMPLES"
    
    # Determine if the node pool is underutilized
    # Account for overhead - consider underutilized if 95th percentile is below 30%
    UTILIZATION_THRESHOLD=30
    OVERHEAD_FACTOR=1.5  # 50% overhead for safety
    
    if [[ $NODE_COUNT -gt 1 ]] && (( $(echo "$CPU_95TH < $UTILIZATION_THRESHOLD" | bc -l) )); then
        progress "Detected underutilization in node pool: $POOL_NAME"
        
        # Calculate cost savings
        hourly_cost_per_node=$(get_azure_vm_cost "$VM_SIZE")
        
        # Estimate reduction potential based on utilization
        if (( $(echo "$CPU_95TH < 15" | bc -l) )); then
            reduction_factor=50  # Can reduce by 50%
        elif (( $(echo "$CPU_95TH < 25" | bc -l) )); then
            reduction_factor=30  # Can reduce by 30%
        else
            reduction_factor=20  # Can reduce by 20%
        fi
        
        # Calculate potential node reduction (conservative)
        removable_nodes=$(( (NODE_COUNT * reduction_factor) / 100 ))
        [[ $removable_nodes -lt 1 ]] && removable_nodes=1
        
        # Ensure we don't go below minimum
        if [[ "$AUTOSCALING_ENABLED" == "true" ]] && [[ $MIN_COUNT -gt 0 ]]; then
            max_removable=$(( NODE_COUNT - MIN_COUNT ))
            [[ $removable_nodes -gt $max_removable ]] && removable_nodes=$max_removable
        fi
        
        # Skip if no savings possible
        if [[ $removable_nodes -le 0 ]]; then
            log "  ℹ️ No cost savings possible due to minimum node constraints"
            continue
        fi
        
        # Calculate monthly savings (24 hours * 30 days)
        monthly_savings_per_node=$(echo "scale=2; $hourly_cost_per_node * 24 * 30" | bc -l)
        total_monthly_savings=$(echo "scale=2; $monthly_savings_per_node * $removable_nodes" | bc -l)
        annual_savings=$(echo "scale=2; $total_monthly_savings * 12" | bc -l)
        
        # Determine severity based on savings bands
        severity=4
        if (( $(echo "$total_monthly_savings > 10000" | bc -l) )); then
            severity=2  # >$10k/month
        elif (( $(echo "$total_monthly_savings > 2000" | bc -l) )); then
            severity=3  # $2k-$10k/month
        else
            severity=4  # <$2k/month
        fi
        
        log "  💰 Cost Savings Opportunity Detected!"
        log "    Potential Monthly Savings: \$${total_monthly_savings}"
        log "    Severity Level: $severity"
        
        add_issue "Possible Cost Savings: Node pool \`$POOL_NAME\` underutilized in AKS cluster \`$AKS_CLUSTER\`" \
                  "AZURE AKS UNDERUTILIZATION COST ANALYSIS:
- Node Pool: $POOL_NAME
- AKS Cluster: $AKS_CLUSTER
- Resource Group: $AZ_RESOURCE_GROUP
- VM Size: $VM_SIZE
- Current Nodes: $NODE_COUNT
- Autoscaling: $AUTOSCALING_ENABLED (Min: $MIN_COUNT, Max: $MAX_COUNT)

30-DAY UTILIZATION TRENDS:
- CPU Average: ${CPU_AVG}%
- CPU 95th Percentile: ${CPU_95TH}%
- CPU Maximum: ${CPU_MAX}%
- Analysis Period: $LOOKBACK_DAYS days
- Data Points: $CPU_SAMPLES samples
- Hourly Cost per Node: \$$hourly_cost_per_node (Azure Pay-as-you-go)

COST SAVINGS OPPORTUNITY:
- Potentially Removable Nodes: $removable_nodes (${reduction_factor}% reduction)
- Monthly Cost per Node: \$$monthly_savings_per_node
- **Estimated Monthly Savings: \$$total_monthly_savings**
- **Annual Savings Potential: \$$annual_savings**

UNDERUTILIZATION ANALYSIS:
This node pool shows consistently low utilization over the past 30 days. The 95th percentile CPU usage of ${CPU_95TH}% indicates that even during peak periods, the nodes are significantly underutilized. This suggests:

1. Over-provisioned infrastructure relative to actual workload demands
2. Opportunity for cost optimization through rightsizing
3. Potential for workload consolidation or node pool scaling
4. Room for implementing more aggressive autoscaling policies

BUSINESS IMPACT:
- Unnecessary infrastructure costs of approximately \$$total_monthly_savings per month
- Inefficient resource allocation across the AKS cluster
- Opportunity for budget reallocation to higher-value initiatives
- Environmental impact from unused compute resources

RECOMMENDATIONS:
1. **Immediate**: Review workload resource requests and limits
2. **Short-term**: Reduce node pool size or implement more aggressive autoscaling
3. **Long-term**: Consider switching to smaller VM sizes or spot instances
4. **Monitoring**: Implement utilization alerts and regular cost reviews

RISK ASSESSMENT:
- Low risk for gradual scaling down with proper monitoring
- Ensure adequate headroom for traffic spikes and workload growth  
- Test scaling changes in non-production environments first
- Monitor application performance during optimization" $severity \
                  "Review node pool utilization: az monitor metrics list --resource '$VMSS_ID' --metric 'Percentage CPU'\\nScale down node pool: az aks nodepool scale --cluster-name '$AKS_CLUSTER' --name '$POOL_NAME' --resource-group '$AZ_RESOURCE_GROUP' --node-count $((NODE_COUNT - removable_nodes))\\nUpdate autoscaling settings: az aks nodepool update --cluster-name '$AKS_CLUSTER' --name '$POOL_NAME' --resource-group '$AZ_RESOURCE_GROUP' --min-count $MIN_COUNT --max-count $((MAX_COUNT - removable_nodes))\\nAnalyze workload resource usage: kubectl top nodes\\nReview pod resource requests: kubectl describe nodes | grep -A5 'Allocated resources'"
    else
        log "  ✅ Node pool utilization is within acceptable range"
    fi
    
    hr
done

# Finalize issues JSON
echo "]" >> "$ISSUES_TMP"
mv "$ISSUES_TMP" "$ISSUES_FILE"

progress "AKS cost optimization analysis completed"
log "Analysis completed at $(date -Iseconds)"
log "Issues file: $ISSUES_FILE"
log "Report file: $REPORT_FILE"
