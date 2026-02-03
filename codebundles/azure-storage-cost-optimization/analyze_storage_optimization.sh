#!/bin/bash

# Azure Storage Cost Optimization Analysis Script
# Analyzes storage resources to identify cost optimization opportunities
# Focuses on:
#   1) Unattached/orphaned managed disks
#   2) Old snapshots (>90 days by default)
#   3) Storage accounts without lifecycle policies
#   4) Over-provisioned redundancy (GRS/GZRS that could use LRS/ZRS)
#   5) Premium storage on low-utilization workloads
#
# Performance Modes:
#   SCAN_MODE=quick   - Fast scan using Resource Graph, skips metrics (default)
#   SCAN_MODE=full    - Full analysis with metrics collection (slower)
#   SCAN_MODE=sample  - Sample N resources and extrapolate
#
# Performance Features:
#   - Azure Resource Graph for bulk queries (10-100x faster)
#   - Parallel metrics collection with controlled concurrency
#   - Quick mode skips expensive per-resource API calls

set -eo pipefail

# Environment variables expected:
# AZURE_SUBSCRIPTION_IDS - Comma-separated list of subscription IDs to analyze (required)
# AZURE_RESOURCE_GROUPS - Comma-separated list of resource groups to analyze (optional, defaults to all)
# COST_ANALYSIS_LOOKBACK_DAYS - Days to look back for metrics (default: 30)
# AZURE_DISCOUNT_PERCENTAGE - Discount percentage off MSRP (optional, defaults to 0)
# SNAPSHOT_AGE_THRESHOLD_DAYS - Age in days for old snapshot detection (default: 90)
# SCAN_MODE - Performance mode: quick (default), full, or sample
# MAX_PARALLEL_JOBS - Maximum parallel metrics collection jobs (default: 10)
# SAMPLE_SIZE - Number of resources to sample in sample mode (default: 20)

# Configuration
LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS:-30}
SNAPSHOT_AGE_DAYS=${SNAPSHOT_AGE_THRESHOLD_DAYS:-90}
REPORT_FILE="storage_optimization_report.txt"
ISSUES_FILE="storage_optimization_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/storage_optimization_issues_$$.json"

# Performance configuration
SCAN_MODE=${SCAN_MODE:-full}  # full (default), quick, or sample
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-10}
SAMPLE_SIZE=${SAMPLE_SIZE:-20}

# Cost thresholds for severity classification
LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD:-500}
MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD:-2000}
HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD:-10000}

# Discount percentage (default to 0 if not set)
DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE:-0}

# Parallel job control
PARALLEL_PIDS=()
METRICS_CACHE_DIR="$TEMP_DIR/metrics_cache_$$"
mkdir -p "$METRICS_CACHE_DIR"

# Initialize outputs
echo -n "[" > "$ISSUES_TMP"
first_issue=true

# Cleanup function
cleanup() {
    if [[ ! -f "$ISSUES_FILE" ]] || [[ ! -s "$ISSUES_FILE" ]]; then
        echo '[]' > "$ISSUES_FILE"
    fi
    rm -f "$ISSUES_TMP" 2>/dev/null || true
    rm -rf "$METRICS_CACHE_DIR" 2>/dev/null || true
    # Kill any remaining background jobs
    for pid in "${PARALLEL_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

#=============================================================================
# PERFORMANCE: Azure Resource Graph queries (10-100x faster than az CLI loops)
#=============================================================================

# Check if Resource Graph extension is available
check_resource_graph() {
    if az extension show --name resource-graph &>/dev/null; then
        return 0
    else
        progress "  Installing Azure Resource Graph extension..."
        az extension add --name resource-graph --yes 2>/dev/null || {
            progress "  ⚠️  Resource Graph not available, falling back to standard queries"
            return 1
        }
    fi
}

# Query unattached disks using Resource Graph (much faster)
query_unattached_disks_graph() {
    local subscription_ids="$1"
    
    local query="Resources
| where type == 'microsoft.compute/disks'
| where properties.diskState == 'Unattached'
| project id, name, resourceGroup, location, 
          diskSizeGb=properties.diskSizeGb,
          sku=sku.name,
          tier=sku.tier,
          timeCreated=properties.timeCreated,
          subscriptionId"
    
    az graph query -q "$query" --subscriptions "$subscription_ids" -o json 2>/dev/null || echo '{"data":[]}'
}

# Query old snapshots using Resource Graph
query_old_snapshots_graph() {
    local subscription_ids="$1"
    local cutoff_date="$2"
    
    local query="Resources
| where type == 'microsoft.compute/snapshots'
| where properties.timeCreated < datetime('$cutoff_date')
| project id, name, resourceGroup, location,
          diskSizeGb=properties.diskSizeGb,
          timeCreated=properties.timeCreated,
          sourceResourceId=properties.creationData.sourceResourceId,
          subscriptionId"
    
    az graph query -q "$query" --subscriptions "$subscription_ids" -o json 2>/dev/null || echo '{"data":[]}'
}

# Query geo-redundant storage accounts using Resource Graph
query_geo_redundant_accounts_graph() {
    local subscription_ids="$1"
    
    local query="Resources
| where type == 'microsoft.storage/storageaccounts'
| where sku.name contains 'GRS' or sku.name contains 'GZRS'
| project id, name, resourceGroup, location,
          skuName=sku.name,
          skuTier=sku.tier,
          kind=kind,
          accessTier=properties.accessTier,
          subscriptionId"
    
    az graph query -q "$query" --subscriptions "$subscription_ids" -o json 2>/dev/null || echo '{"data":[]}'
}

# Query Premium disks using Resource Graph
query_premium_disks_graph() {
    local subscription_ids="$1"
    
    local query="Resources
| where type == 'microsoft.compute/disks'
| where sku.tier == 'Premium'
| where properties.diskState == 'Attached'
| project id, name, resourceGroup, location,
          diskSizeGb=properties.diskSizeGb,
          sku=sku.name,
          diskIOPSReadWrite=properties.diskIOPSReadWrite,
          diskMBpsReadWrite=properties.diskMBpsReadWrite,
          subscriptionId"
    
    az graph query -q "$query" --subscriptions "$subscription_ids" -o json 2>/dev/null || echo '{"data":[]}'
}

# Query all storage accounts using Resource Graph
query_all_storage_accounts_graph() {
    local subscription_ids="$1"
    
    local query="Resources
| where type == 'microsoft.storage/storageaccounts'
| project id, name, resourceGroup, location,
          skuName=sku.name,
          kind=kind,
          accessTier=properties.accessTier,
          subscriptionId"
    
    az graph query -q "$query" --subscriptions "$subscription_ids" -o json 2>/dev/null || echo '{"data":[]}'
}

#=============================================================================
# PERFORMANCE: Parallel metrics collection
#=============================================================================

# Semaphore for controlling parallel jobs
wait_for_slot() {
    while [[ ${#PARALLEL_PIDS[@]} -ge $MAX_PARALLEL_JOBS ]]; do
        local new_pids=()
        for pid in "${PARALLEL_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                new_pids+=("$pid")
            fi
        done
        PARALLEL_PIDS=("${new_pids[@]}")
        [[ ${#PARALLEL_PIDS[@]} -ge $MAX_PARALLEL_JOBS ]] && sleep 0.5
    done
}

# Collect storage metrics in background
collect_storage_metrics_async() {
    local account_id="$1"
    local account_name="$2"
    local output_file="$3"
    
    (
        local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local start_time=$(date -u -d "1 day ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1d +"%Y-%m-%dT%H:%M:%SZ")
        
        local metrics=$(az monitor metrics list \
            --resource "$account_id" \
            --metric "UsedCapacity" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --interval PT1H \
            --aggregation Average \
            -o json 2>/dev/null || echo '{}')
        
        local used_bytes=$(echo "$metrics" | jq -r '[.value[0].timeseries[0].data[]? | select(.average != null) | .average] | if length > 0 then (add / length) else 0 end' 2>/dev/null || echo "0")
        local used_gb=$(echo "scale=2; ${used_bytes:-0} / 1073741824" | bc -l 2>/dev/null || echo "0")
        
        echo "$used_gb" > "$output_file"
    ) &
    
    PARALLEL_PIDS+=($!)
}

# Wait for all parallel jobs to complete
wait_all_parallel() {
    for pid in "${PARALLEL_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    PARALLEL_PIDS=()
}

#=============================================================================
# PERFORMANCE: Estimate storage usage without metrics (for quick mode)
#=============================================================================

# Estimate storage account size based on account kind and tier (rough estimate)
estimate_storage_size_gb() {
    local account_kind="$1"
    local account_tier="$2"
    
    # Conservative estimates based on typical usage patterns
    # These are used in quick mode when we skip metrics collection
    case "${account_kind,,}" in
        storagev2|storage)
            echo "100"  # Default estimate for general purpose
            ;;
        blobstorage)
            echo "500"  # Blob-only tends to be larger
            ;;
        filestorage)
            echo "200"  # File shares
            ;;
        blockblobstorage)
            echo "1000" # Block blob tends to be large
            ;;
        *)
            echo "100"
            ;;
    esac
}

# Logging functions
log() { printf "%s\n" "$*" >> "$REPORT_FILE"; }
hr() { printf -- '─%.0s' {1..80} >> "$REPORT_FILE"; printf "\n" >> "$REPORT_FILE"; }
progress() { printf "💾 [%s] %s\n" "$(date '+%H:%M:%S')" "$*" >&2; }

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

# Azure Managed Disk Pricing (monthly, USD, Central US region, LRS)
get_disk_cost() {
    local disk_sku="$1"
    local disk_size_gb="$2"
    local disk_sku_lower=$(echo "$disk_sku" | tr '[:upper:]' '[:lower:]')
    
    case "$disk_sku_lower" in
        # Premium SSD v2 - priced per GB + IOPS + throughput
        premiumv2_lrs)
            echo "scale=2; $disk_size_gb * 0.122" | bc -l
            ;;
        # Premium SSD
        premium_lrs|premium_zrs)
            if [[ $disk_size_gb -le 4 ]]; then echo "0.77"
            elif [[ $disk_size_gb -le 8 ]]; then echo "1.54"
            elif [[ $disk_size_gb -le 16 ]]; then echo "2.95"
            elif [[ $disk_size_gb -le 32 ]]; then echo "5.67"
            elif [[ $disk_size_gb -le 64 ]]; then echo "10.90"
            elif [[ $disk_size_gb -le 128 ]]; then echo "21.02"
            elif [[ $disk_size_gb -le 256 ]]; then echo "40.48"
            elif [[ $disk_size_gb -le 512 ]]; then echo "78.03"
            elif [[ $disk_size_gb -le 1024 ]]; then echo "150.34"
            elif [[ $disk_size_gb -le 2048 ]]; then echo "289.85"
            elif [[ $disk_size_gb -le 4096 ]]; then echo "558.69"
            elif [[ $disk_size_gb -le 8192 ]]; then echo "1075.84"
            elif [[ $disk_size_gb -le 16384 ]]; then echo "2071.04"
            else echo "3985.92"
            fi
            ;;
        # Standard SSD
        standardssd_lrs|standardssd_zrs)
            if [[ $disk_size_gb -le 4 ]]; then echo "0.30"
            elif [[ $disk_size_gb -le 8 ]]; then echo "0.60"
            elif [[ $disk_size_gb -le 16 ]]; then echo "1.15"
            elif [[ $disk_size_gb -le 32 ]]; then echo "2.21"
            elif [[ $disk_size_gb -le 64 ]]; then echo "4.24"
            elif [[ $disk_size_gb -le 128 ]]; then echo "8.17"
            elif [[ $disk_size_gb -le 256 ]]; then echo "15.75"
            elif [[ $disk_size_gb -le 512 ]]; then echo "30.34"
            elif [[ $disk_size_gb -le 1024 ]]; then echo "58.44"
            elif [[ $disk_size_gb -le 2048 ]]; then echo "112.61"
            elif [[ $disk_size_gb -le 4096 ]]; then echo "217.06"
            elif [[ $disk_size_gb -le 8192 ]]; then echo "418.30"
            elif [[ $disk_size_gb -le 16384 ]]; then echo "806.08"
            else echo "1553.53"
            fi
            ;;
        # Standard HDD
        standard_lrs|standard_zrs)
            if [[ $disk_size_gb -le 32 ]]; then echo "1.54"
            elif [[ $disk_size_gb -le 64 ]]; then echo "3.00"
            elif [[ $disk_size_gb -le 128 ]]; then echo "5.89"
            elif [[ $disk_size_gb -le 256 ]]; then echo "11.52"
            elif [[ $disk_size_gb -le 512 ]]; then echo "22.53"
            elif [[ $disk_size_gb -le 1024 ]]; then echo "44.06"
            elif [[ $disk_size_gb -le 2048 ]]; then echo "86.22"
            elif [[ $disk_size_gb -le 4096 ]]; then echo "168.71"
            elif [[ $disk_size_gb -le 8192 ]]; then echo "330.24"
            elif [[ $disk_size_gb -le 16384 ]]; then echo "646.68"
            else echo "1266.00"
            fi
            ;;
        # Default - estimate based on Standard SSD
        *)
            echo "scale=2; $disk_size_gb * 0.06" | bc -l
            ;;
    esac
}

# Get snapshot cost per GB per month
get_snapshot_cost_per_gb() {
    # Azure snapshots are charged at ~$0.05/GB/month for standard
    echo "0.05"
}

# Storage account redundancy costs (relative multipliers)
get_redundancy_savings() {
    local current_redundancy="$1"
    local suggested_redundancy="$2"
    
    # Approximate cost multipliers relative to LRS (1.0)
    # LRS = 1.0, ZRS = 1.25, GRS = 2.0, GZRS = 2.5, RA-GRS = 2.1, RA-GZRS = 2.6
    local current_mult=1.0
    local suggested_mult=1.0
    
    case "${current_redundancy^^}" in
        LRS) current_mult=1.0 ;;
        ZRS) current_mult=1.25 ;;
        GRS) current_mult=2.0 ;;
        GZRS) current_mult=2.5 ;;
        RAGRS|RA-GRS) current_mult=2.1 ;;
        RAGZRS|RA-GZRS) current_mult=2.6 ;;
    esac
    
    case "${suggested_redundancy^^}" in
        LRS) suggested_mult=1.0 ;;
        ZRS) suggested_mult=1.25 ;;
        GRS) suggested_mult=2.0 ;;
        GZRS) suggested_mult=2.5 ;;
        RAGRS|RA-GRS) suggested_mult=2.1 ;;
        RAGZRS|RA-GZRS) suggested_mult=2.6 ;;
    esac
    
    # Return savings percentage (use scale=4 for division, then truncate to integer)
    printf "%.0f" "$(echo "scale=4; (1 - ($suggested_mult / $current_mult)) * 100" | bc -l)"
}

# Get redundancy multiplier for cost calculation
get_redundancy_multiplier() {
    local redundancy="$1"
    case "${redundancy^^}" in
        LRS) echo "1.0" ;;
        ZRS) echo "1.25" ;;
        GRS) echo "2.0" ;;
        GZRS) echo "2.5" ;;
        RAGRS|RA-GRS) echo "2.1" ;;
        RAGZRS|RA-GZRS) echo "2.6" ;;
        *) echo "1.0" ;;
    esac
}

# Azure Blob Storage pricing per GB per month (Hot tier, LRS baseline - USD)
# These are approximate MSRP prices for common regions (2024/2025)
get_storage_price_per_gb() {
    local region="$1"
    local access_tier="$2"
    
    # Normalize region name (remove spaces, lowercase)
    local region_lower=$(echo "$region" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    
    # Base price per GB/month for Hot tier LRS (approximate MSRP)
    # Prices vary by region - using representative values
    local base_price=0.0184  # Default Hot tier
    
    case "$region_lower" in
        eastus|eastus2|westus|westus2|centralus|northcentralus|southcentralus)
            base_price=0.0184  # US regions
            ;;
        westeurope|northeurope|uksouth|ukwest|francecentral|germanywestcentral)
            base_price=0.0208  # European regions
            ;;
        eastasia|southeastasia|japaneast|japanwest|koreacentral|koreasouth)
            base_price=0.0220  # Asia Pacific regions
            ;;
        australiaeast|australiasoutheast|australiacentral)
            base_price=0.0230  # Australia regions
            ;;
        brazilsouth)
            base_price=0.0350  # Brazil (typically higher)
            ;;
        *)
            base_price=0.0200  # Default fallback
            ;;
    esac
    
    # Adjust for access tier
    case "${access_tier,,}" in
        hot)
            echo "$base_price"
            ;;
        cool)
            echo "$(echo "scale=6; $base_price * 0.5" | bc -l)"  # ~50% of hot
            ;;
        cold)
            echo "$(echo "scale=6; $base_price * 0.25" | bc -l)" # ~25% of hot
            ;;
        archive)
            echo "$(echo "scale=6; $base_price * 0.05" | bc -l)" # ~5% of hot
            ;;
        *)
            echo "$base_price"
            ;;
    esac
}

# Get storage account used capacity in GB
get_storage_account_usage_gb() {
    local account_id="$1"
    local account_name="$2"
    
    # Get UsedCapacity metric (in bytes) - average over last 24 hours
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "1 day ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-1d +"%Y-%m-%dT%H:%M:%SZ")
    
    local metrics=$(az monitor metrics list \
        --resource "$account_id" \
        --metric "UsedCapacity" \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation Average \
        -o json 2>/dev/null || echo '{}')
    
    # Extract average used capacity in bytes, convert to GB
    local used_bytes=$(echo "$metrics" | jq -r '[.value[0].timeseries[0].data[]? | select(.average != null) | .average] | if length > 0 then (add / length) else 0 end' 2>/dev/null || echo "0")
    
    if [[ -z "$used_bytes" || "$used_bytes" == "null" || "$used_bytes" == "0" ]]; then
        # Fallback: Try to get blob service properties
        local blob_capacity=$(az storage account show \
            --ids "$account_id" \
            --query "primaryEndpoints.blob" \
            -o tsv 2>/dev/null)
        
        # If metrics not available, return 0 and note it
        echo "0"
        return
    fi
    
    # Convert bytes to GB (divide by 1024^3)
    local used_gb=$(echo "scale=2; $used_bytes / 1073741824" | bc -l 2>/dev/null || echo "0")
    echo "$used_gb"
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

# Analysis 1: Find unattached managed disks
analyze_unattached_disks() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking for unattached managed disks..."
    
    local disks
    
    # Use Resource Graph for faster queries
    if [[ "$USE_RESOURCE_GRAPH" == "true" ]]; then
        local graph_result=$(query_unattached_disks_graph "$subscription_id")
        disks=$(echo "$graph_result" | jq '[.data[] | {
            name: .name,
            id: .id,
            resourceGroup: .resourceGroup,
            location: .location,
            diskSizeGb: .diskSizeGb,
            sku: {name: .sku},
            tier: .tier,
            timeCreated: .timeCreated
        }]')
    else
        disks=$(az disk list --subscription "$subscription_id" \
            --query "[?diskState=='Unattached']" -o json 2>/dev/null || echo '[]')
    fi
    
    local disk_count=$(echo "$disks" | jq 'length')
    
    if [[ "$disk_count" -eq 0 ]]; then
        progress "  ✓ No unattached disks found"
        log "  ✓ No unattached managed disks found"
        return
    fi
    
    progress "  ⚠️  Found $disk_count unattached disk(s)"
    log "  Found $disk_count unattached managed disk(s):"
    log ""
    
    local total_savings=0
    local disk_details=""
    
    while IFS= read -r disk_data; do
        local disk_name=$(echo "$disk_data" | jq -r '.name')
        local disk_id=$(echo "$disk_data" | jq -r '.id')
        local disk_rg=$(echo "$disk_data" | jq -r '.resourceGroup')
        local disk_location=$(echo "$disk_data" | jq -r '.location')
        local disk_size_gb=$(echo "$disk_data" | jq -r '.diskSizeGb // 0')
        local disk_sku=$(echo "$disk_data" | jq -r '.sku.name // "Standard_LRS"')
        local disk_tier=$(echo "$disk_data" | jq -r '.tier // "Unknown"')
        local time_created=$(echo "$disk_data" | jq -r '.timeCreated // "Unknown"')
        
        local monthly_cost=$(get_disk_cost "$disk_sku" "$disk_size_gb")
        monthly_cost=$(apply_discount "$monthly_cost")
        total_savings=$(echo "scale=2; $total_savings + $monthly_cost" | bc -l)
        
        disk_details="${disk_details}
  • $disk_name
    - Resource Group: $disk_rg
    - Size: ${disk_size_gb} GB
    - SKU: $disk_sku
    - Created: $time_created
    - Monthly Cost: \$${monthly_cost}"
        
        log "    • $disk_name (${disk_size_gb}GB, $disk_sku) - \$${monthly_cost}/month"
    done < <(echo "$disks" | jq -c '.[]')
    
    if (( $(echo "$total_savings > 0" | bc -l) )); then
        local annual_savings=$(echo "scale=2; $total_savings * 12" | bc -l)
        local severity=$(get_severity_for_savings "$total_savings")
        
        local details="UNATTACHED MANAGED DISKS - WASTING COSTS:

Subscription: $subscription_name ($subscription_id)
Total Unattached Disks: $disk_count
Total Monthly Waste: \$$total_savings
Total Annual Waste: \$$annual_savings

DISK INVENTORY:
$disk_details

ISSUE:
These disks are not attached to any VM but continue to incur storage costs.
Common causes:
- VM was deleted but disk was preserved
- Snapshot restored to new disk but never attached
- Test/dev disk no longer needed

RECOMMENDATION:
Review each disk and either:
1. Attach to an existing VM if needed
2. Delete if no longer required
3. Create a snapshot before deletion if data might be needed"

        local next_steps="IMMEDIATE ACTIONS - Review and Clean Up Unattached Disks:

Azure Portal:
1. Go to 'Disks' service
2. Filter by 'Disk state' = 'Unattached'
3. Review each disk's data/purpose
4. Delete unused disks

Azure CLI - List all unattached disks:
az disk list --subscription '$subscription_id' --query \"[?diskState=='Unattached'].{Name:name, RG:resourceGroup, Size:diskSizeGb, SKU:sku.name}\" -o table

Azure CLI - Delete a specific disk:
az disk delete --name '<disk-name>' --resource-group '<resource-group>' --subscription '$subscription_id' --yes

⚠️  CAUTION: Verify disk contents before deletion. Consider creating a snapshot first if unsure."

        add_issue "Unattached Managed Disks: $disk_count disk(s) wasting \$$total_savings/month" "$details" "$severity" "$next_steps"
    fi
}

# Analysis 2: Find old snapshots
analyze_old_snapshots() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking for old snapshots (>${SNAPSHOT_AGE_DAYS} days)..."
    
    local cutoff_date=$(date -u -d "$SNAPSHOT_AGE_DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-${SNAPSHOT_AGE_DAYS}d +"%Y-%m-%dT%H:%M:%SZ")
    
    local old_snapshots
    
    # Use Resource Graph for faster queries
    if [[ "$USE_RESOURCE_GRAPH" == "true" ]]; then
        local graph_result=$(query_old_snapshots_graph "$subscription_id" "$cutoff_date")
        old_snapshots=$(echo "$graph_result" | jq '[.data[] | {
            name: .name,
            id: .id,
            resourceGroup: .resourceGroup,
            location: .location,
            diskSizeGb: .diskSizeGb,
            timeCreated: .timeCreated,
            creationData: {sourceResourceId: .sourceResourceId}
        }]')
    else
        local snapshots=$(az snapshot list --subscription "$subscription_id" -o json 2>/dev/null || echo '[]')
        # Filter old snapshots (exclude those with null timeCreated)
        old_snapshots=$(echo "$snapshots" | jq --arg cutoff "$cutoff_date" \
            '[.[] | select(.timeCreated != null and .timeCreated < $cutoff)]')
    fi
    
    local snapshot_count=$(echo "$old_snapshots" | jq 'length')
    
    if [[ "$snapshot_count" -eq 0 ]]; then
        progress "  ✓ No old snapshots found"
        log "  ✓ No snapshots older than $SNAPSHOT_AGE_DAYS days"
        return
    fi
    
    progress "  ⚠️  Found $snapshot_count old snapshot(s)"
    log "  Found $snapshot_count snapshot(s) older than $SNAPSHOT_AGE_DAYS days:"
    log ""
    
    local total_size_gb=0
    local total_savings=0
    local snapshot_details=""
    local cost_per_gb=$(get_snapshot_cost_per_gb)
    
    while IFS= read -r snapshot_data; do
        local snap_name=$(echo "$snapshot_data" | jq -r '.name')
        local snap_rg=$(echo "$snapshot_data" | jq -r '.resourceGroup')
        local snap_size_gb=$(echo "$snapshot_data" | jq -r '.diskSizeGb // 0')
        local time_created=$(echo "$snapshot_data" | jq -r '.timeCreated // empty')
        local source_disk=$(echo "$snapshot_data" | jq -r '.creationData.sourceResourceId // "Unknown"' | sed 's|.*/||')
        
        # Skip if timeCreated is empty or invalid
        if [[ -z "$time_created" || "$time_created" == "null" ]]; then
            progress "  ⚠️  Skipping snapshot $snap_name - missing creation date"
            continue
        fi
        
        # Parse the date and validate it succeeded
        local created_epoch
        created_epoch=$(date -d "$time_created" +%s 2>/dev/null)
        if [[ -z "$created_epoch" || "$created_epoch" == "0" ]]; then
            progress "  ⚠️  Skipping snapshot $snap_name - could not parse creation date: $time_created"
            continue
        fi
        
        local current_epoch=$(date +%s)
        local age_days=$(( (current_epoch - created_epoch) / 86400 ))
        
        # Skip if age is unreasonable (negative or older than Azure itself - 2010, ~15 years)
        if [[ $age_days -lt 0 || $age_days -gt 5500 ]]; then
            progress "  ⚠️  Skipping snapshot $snap_name - invalid age calculated: ${age_days} days"
            continue
        fi
        local monthly_cost=$(echo "scale=2; $snap_size_gb * $cost_per_gb" | bc -l)
        monthly_cost=$(apply_discount "$monthly_cost")
        
        total_size_gb=$(echo "$total_size_gb + $snap_size_gb" | bc)
        total_savings=$(echo "scale=2; $total_savings + $monthly_cost" | bc -l)
        
        snapshot_details="${snapshot_details}
  • $snap_name
    - Resource Group: $snap_rg
    - Size: ${snap_size_gb} GB
    - Age: ${age_days} days
    - Source Disk: $source_disk
    - Monthly Cost: \$${monthly_cost}"
        
        log "    • $snap_name (${snap_size_gb}GB, ${age_days} days old) - \$${monthly_cost}/month"
    done < <(echo "$old_snapshots" | jq -c '.[]')
    
    if (( $(echo "$total_savings > 0" | bc -l) )); then
        local annual_savings=$(echo "scale=2; $total_savings * 12" | bc -l)
        local severity=$(get_severity_for_savings "$total_savings")
        
        local details="OLD SNAPSHOTS CONSUMING STORAGE COSTS:

Subscription: $subscription_name ($subscription_id)
Total Old Snapshots: $snapshot_count
Total Size: ${total_size_gb} GB
Age Threshold: $SNAPSHOT_AGE_DAYS days
Total Monthly Cost: \$$total_savings
Total Annual Cost: \$$annual_savings

SNAPSHOT INVENTORY:
$snapshot_details

ISSUE:
These snapshots are older than $SNAPSHOT_AGE_DAYS days and may no longer be needed.
Common causes:
- One-time backup snapshots never cleaned up
- Automated snapshots without retention policy
- Pre-migration/upgrade snapshots kept 'just in case'

RECOMMENDATION:
1. Review snapshot purpose and source disk
2. Delete snapshots that are no longer needed
3. Implement automated retention policies for future snapshots"

        local next_steps="ACTIONS - Review and Clean Up Old Snapshots:

Azure Portal:
1. Go to 'Snapshots' service
2. Sort by 'Time created' (oldest first)
3. Review each snapshot's purpose
4. Delete unused snapshots

Azure CLI - List all snapshots older than ${SNAPSHOT_AGE_DAYS} days:
az snapshot list --subscription '$subscription_id' --query \"[?timeCreated<'$cutoff_date'].{Name:name, RG:resourceGroup, Size:diskSizeGb, Created:timeCreated}\" -o table

Azure CLI - Delete a specific snapshot:
az snapshot delete --name '<snapshot-name>' --resource-group '<resource-group>' --subscription '$subscription_id' --yes

BEST PRACTICE - Set up automated cleanup:
Consider using Azure Automation or Azure Policy to automatically delete snapshots older than your retention period."

        add_issue "Old Snapshots: $snapshot_count snapshot(s) (${total_size_gb}GB) costing \$$total_savings/month" "$details" "$severity" "$next_steps"
    fi
}

# Analysis 3: Check storage accounts without lifecycle policies
analyze_lifecycle_policies() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking storage accounts for lifecycle management policies..."
    
    local storage_accounts=$(az storage account list --subscription "$subscription_id" -o json 2>/dev/null || echo '[]')
    local account_count=$(echo "$storage_accounts" | jq 'length')
    
    if [[ "$account_count" -eq 0 ]]; then
        progress "  ✓ No storage accounts found"
        log "  ✓ No storage accounts to analyze"
        return
    fi
    
    progress "  Found $account_count storage account(s) to analyze"
    
    local accounts_without_policy=0
    local hot_tier_accounts=0
    local account_details=""
    
    while IFS= read -r account_data; do
        local account_name=$(echo "$account_data" | jq -r '.name')
        local account_rg=$(echo "$account_data" | jq -r '.resourceGroup')
        local account_kind=$(echo "$account_data" | jq -r '.kind')
        local access_tier=$(echo "$account_data" | jq -r '.accessTier // "N/A"')
        local replication=$(echo "$account_data" | jq -r '.sku.name' | sed 's/.*_//')
        
        # Skip classic storage accounts (they don't support lifecycle management)
        if [[ "$account_kind" == "Storage" ]]; then
            continue
        fi
        
        # Check for lifecycle management policy
        local policy_exists=$(az storage account management-policy show \
            --account-name "$account_name" \
            --resource-group "$account_rg" \
            --subscription "$subscription_id" \
            -o json 2>/dev/null || echo '{"policy":null}')
        
        local has_policy=$(echo "$policy_exists" | jq -r '.policy.rules // empty | length > 0')
        
        if [[ "$has_policy" != "true" ]]; then
            accounts_without_policy=$((accounts_without_policy + 1))
            
            if [[ "$access_tier" == "Hot" ]]; then
                hot_tier_accounts=$((hot_tier_accounts + 1))
            fi
            
            account_details="${account_details}
  • $account_name
    - Resource Group: $account_rg
    - Kind: $account_kind
    - Access Tier: $access_tier
    - Replication: $replication
    - Lifecycle Policy: ❌ NOT CONFIGURED"
            
            log "    • $account_name ($account_kind, $access_tier tier) - NO lifecycle policy"
        fi
    done < <(echo "$storage_accounts" | jq -c '.[]')
    
    if [[ $accounts_without_policy -gt 0 ]]; then
        # Estimate savings based on Hot tier accounts
        # Assume 10% of data could be moved to Cool (60% cheaper) and 10% to Archive (95% cheaper)
        # This is a conservative estimate - actual savings depend on data access patterns
        
        local details="STORAGE ACCOUNTS WITHOUT LIFECYCLE MANAGEMENT:

Subscription: $subscription_name ($subscription_id)
Storage Accounts Without Policies: $accounts_without_policy
Hot Tier Accounts (highest savings potential): $hot_tier_accounts

ACCOUNTS WITHOUT LIFECYCLE POLICIES:
$account_details

ISSUE:
These storage accounts don't have lifecycle management policies configured.
Without lifecycle policies:
- All data stays in its original tier forever
- Old/inactive data continues at Hot tier pricing
- No automatic cleanup of old versions or deleted blobs

POTENTIAL SAVINGS (Tier Comparison):
- Hot → Cool: ~60% savings on storage costs
- Hot → Archive: ~95% savings on storage costs
- Example: 1TB Hot (\$20/month) → Archive (\$1/month)

RECOMMENDATION:
Configure lifecycle management policies to:
1. Move data to Cool tier after 30-90 days of no access
2. Move data to Archive tier after 180+ days
3. Delete old blob versions and soft-deleted items"

        local severity=4
        if [[ $hot_tier_accounts -ge 3 ]]; then
            severity=3
        fi
        
        local next_steps="ACTIONS - Configure Lifecycle Management Policies:

Azure Portal:
1. Go to Storage Account → Data management → Lifecycle management
2. Add rule to transition blobs to Cool tier after 30-90 days
3. Add rule to transition to Archive tier after 180+ days
4. Add rule to delete old blob versions after retention period

Azure CLI - Create a sample lifecycle policy:
cat > lifecycle-policy.json << 'EOF'
{
  \"rules\": [
    {
      \"name\": \"MoveToCoolAfter30Days\",
      \"enabled\": true,
      \"type\": \"Lifecycle\",
      \"definition\": {
        \"filters\": {\"blobTypes\": [\"blockBlob\"]},
        \"actions\": {
          \"baseBlob\": {
            \"tierToCool\": {\"daysAfterModificationGreaterThan\": 30},
            \"tierToArchive\": {\"daysAfterModificationGreaterThan\": 180}
          }
        }
      }
    }
  ]
}
EOF

az storage account management-policy create \\
  --account-name '<account-name>' \\
  --resource-group '<resource-group>' \\
  --subscription '$subscription_id' \\
  --policy @lifecycle-policy.json

⚠️  NOTE: Archive tier has retrieval costs and latency. Ensure data access patterns support archival."

        add_issue "Storage Lifecycle: $accounts_without_policy account(s) without lifecycle policies" "$details" "$severity" "$next_steps"
    else
        progress "  ✓ All storage accounts have lifecycle policies configured"
        log "  ✓ All storage accounts have lifecycle management policies"
    fi
}

# Analysis 4: Check for over-provisioned redundancy with actual cost estimation
analyze_redundancy() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking for over-provisioned storage redundancy (mode: $SCAN_MODE)..."
    
    local storage_accounts
    
    # Use Resource Graph for faster queries if available
    if [[ "$USE_RESOURCE_GRAPH" == "true" ]]; then
        progress "  Using Azure Resource Graph for fast query..."
        local graph_result=$(query_geo_redundant_accounts_graph "$subscription_id")
        storage_accounts=$(echo "$graph_result" | jq '[.data[] | {
            name: .name,
            id: .id,
            resourceGroup: .resourceGroup,
            kind: .kind,
            location: .location,
            sku: {name: .skuName},
            accessTier: .accessTier
        }]')
    else
        storage_accounts=$(az storage account list --subscription "$subscription_id" \
            --query "[?sku.name=='Standard_GRS' || sku.name=='Standard_RAGRS' || sku.name=='Standard_GZRS' || sku.name=='Standard_RAGZRS']" \
            -o json 2>/dev/null || echo '[]')
    fi
    
    local account_count=$(echo "$storage_accounts" | jq 'length')
    
    if [[ "$account_count" -eq 0 ]]; then
        progress "  ✓ No geo-redundant storage accounts found to review"
        log "  ✓ No geo-redundant storage accounts to review"
        return
    fi
    
    progress "  Found $account_count geo-redundant storage account(s) - collecting usage data..."
    log "  Found $account_count geo-redundant storage account(s):"
    log ""
    
    local account_details=""
    local total_used_gb=0
    local total_current_monthly_cost=0
    local total_lrs_monthly_cost=0
    local total_monthly_savings=0
    local accounts_with_usage=0
    local accounts_without_metrics=0
    
    # Create savings report table header
    local savings_table="
┌─────────────────────────────────┬────────────┬──────────────┬──────────────┬───────────────┬─────────────┬──────────────┐
│ Storage Account                 │ Region     │ Used (GB)    │ Redundancy   │ Current Cost  │ LRS Cost    │ Savings      │
├─────────────────────────────────┼────────────┼──────────────┼──────────────┼───────────────┼─────────────┼──────────────┤"
    
    # PERFORMANCE: In full mode, pre-collect metrics in parallel
    if [[ "$SCAN_MODE" == "full" ]] && [[ "$account_count" -gt 5 ]]; then
        progress "  Pre-collecting metrics in parallel (max $MAX_PARALLEL_JOBS concurrent)..."
        
        local idx=0
        while IFS= read -r account_data; do
            local account_name=$(echo "$account_data" | jq -r '.name')
            local account_id=$(echo "$account_data" | jq -r '.id')
            local cache_file="$METRICS_CACHE_DIR/${account_name}.usage"
            
            wait_for_slot
            collect_storage_metrics_async "$account_id" "$account_name" "$cache_file"
            
            idx=$((idx + 1))
            [[ $((idx % 10)) -eq 0 ]] && progress "    Queued $idx/$account_count accounts..."
        done < <(echo "$storage_accounts" | jq -c '.[]')
        
        progress "  Waiting for parallel metrics collection to complete..."
        wait_all_parallel
        progress "  ✓ Metrics collection complete"
    fi
    
    # Determine sample set for sample mode
    local sample_indices=""
    if [[ "$SCAN_MODE" == "sample" ]] && [[ "$account_count" -gt "$SAMPLE_SIZE" ]]; then
        progress "  Sample mode: analyzing $SAMPLE_SIZE of $account_count accounts..."
        # Generate random sample indices
        sample_indices=$(shuf -i 0-$((account_count-1)) -n "$SAMPLE_SIZE" | sort -n | tr '\n' ' ')
    fi
    
    local current_idx=0
    while IFS= read -r account_data; do
        local account_name=$(echo "$account_data" | jq -r '.name')
        local account_id=$(echo "$account_data" | jq -r '.id')
        local account_rg=$(echo "$account_data" | jq -r '.resourceGroup')
        local account_kind=$(echo "$account_data" | jq -r '.kind')
        local sku_name=$(echo "$account_data" | jq -r '.sku.name')
        local replication=$(echo "$sku_name" | sed 's/Standard_//' | sed 's/Premium_//')
        local access_tier=$(echo "$account_data" | jq -r '.accessTier // "Hot"')
        local location=$(echo "$account_data" | jq -r '.location')
        
        # Check if we should skip this account in sample mode
        if [[ "$SCAN_MODE" == "sample" ]] && [[ -n "$sample_indices" ]]; then
            if ! echo "$sample_indices" | grep -qw "$current_idx"; then
                current_idx=$((current_idx + 1))
                continue
            fi
        fi
        
        current_idx=$((current_idx + 1))
        
        local used_gb=0
        
        # Get storage usage based on mode
        case "$SCAN_MODE" in
            quick)
                # Use estimate based on account type (no API calls)
                used_gb=$(estimate_storage_size_gb "$account_kind" "$access_tier")
                ;;
            full)
                # Check cache first (from parallel collection)
                local cache_file="$METRICS_CACHE_DIR/${account_name}.usage"
                if [[ -f "$cache_file" ]]; then
                    used_gb=$(cat "$cache_file")
                else
                    # Fallback to direct query
                    progress "    Analyzing $account_name..."
                    used_gb=$(get_storage_account_usage_gb "$account_id" "$account_name")
                fi
                ;;
            sample)
                # Collect actual metrics for sampled accounts
                progress "    Sampling $account_name..."
                used_gb=$(get_storage_account_usage_gb "$account_id" "$account_name")
                ;;
        esac
        
        # Get base price per GB for the region and tier
        local base_price_per_gb=$(get_storage_price_per_gb "$location" "$access_tier")
        
        # Get redundancy multipliers
        local current_multiplier=$(get_redundancy_multiplier "$replication")
        local lrs_multiplier=$(get_redundancy_multiplier "LRS")
        
        # Calculate costs
        local current_monthly_cost=0
        local lrs_monthly_cost=0
        local monthly_savings=0
        
        if [[ "$used_gb" != "0" ]] && (( $(echo "$used_gb > 0" | bc -l 2>/dev/null || echo "0") )); then
            accounts_with_usage=$((accounts_with_usage + 1))
            total_used_gb=$(echo "scale=2; $total_used_gb + $used_gb" | bc -l)
            
            # Current monthly cost = used_gb * base_price * redundancy_multiplier
            current_monthly_cost=$(echo "scale=2; $used_gb * $base_price_per_gb * $current_multiplier" | bc -l)
            current_monthly_cost=$(apply_discount "$current_monthly_cost")
            
            # LRS monthly cost = used_gb * base_price * lrs_multiplier
            lrs_monthly_cost=$(echo "scale=2; $used_gb * $base_price_per_gb * $lrs_multiplier" | bc -l)
            lrs_monthly_cost=$(apply_discount "$lrs_monthly_cost")
            
            # Monthly savings
            monthly_savings=$(echo "scale=2; $current_monthly_cost - $lrs_monthly_cost" | bc -l)
            
            total_current_monthly_cost=$(echo "scale=2; $total_current_monthly_cost + $current_monthly_cost" | bc -l)
            total_lrs_monthly_cost=$(echo "scale=2; $total_lrs_monthly_cost + $lrs_monthly_cost" | bc -l)
            total_monthly_savings=$(echo "scale=2; $total_monthly_savings + $monthly_savings" | bc -l)
        else
            accounts_without_metrics=$((accounts_without_metrics + 1))
        fi
        
        local savings_pct=$(get_redundancy_savings "$replication" "LRS")
        
        # Format for table (truncate long names)
        local name_display=$(printf "%-31s" "${account_name:0:31}")
        local region_display=$(printf "%-10s" "${location:0:10}")
        local used_display=$(printf "%12.2f" "$used_gb")
        local repl_display=$(printf "%-12s" "$replication")
        local current_display=$(printf "\$%11.2f" "$current_monthly_cost")
        local lrs_display=$(printf "\$%10.2f" "$lrs_monthly_cost")
        local savings_display=$(printf "\$%10.2f" "$monthly_savings")
        
        savings_table="${savings_table}
│ $name_display │ $region_display │ $used_display │ $repl_display │ $current_display │ $lrs_display │ $savings_display │"
        
        account_details="${account_details}
  • $account_name
    - Resource Group: $account_rg
    - Kind: $account_kind
    - Region: $location
    - Current SKU: $sku_name
    - Replication: $replication
    - Access Tier: $access_tier
    - Used Capacity: ${used_gb} GB
    - Current Monthly Cost: \$$current_monthly_cost
    - LRS Monthly Cost: \$$lrs_monthly_cost
    - Potential Monthly Savings: \$$monthly_savings (~${savings_pct}%)"
        
        log "    • $account_name ($replication, ${used_gb}GB) - \$$current_monthly_cost/mo → \$$lrs_monthly_cost/mo (save \$$monthly_savings)"
    done < <(echo "$storage_accounts" | jq -c '.[]')
    
    # Close table
    savings_table="${savings_table}
├─────────────────────────────────┼────────────┼──────────────┼──────────────┼───────────────┼─────────────┼──────────────┤
│ TOTAL                           │            │ $(printf "%12.2f" "$total_used_gb") │              │ $(printf "\$%11.2f" "$total_current_monthly_cost") │ $(printf "\$%10.2f" "$total_lrs_monthly_cost") │ $(printf "\$%10.2f" "$total_monthly_savings") │
└─────────────────────────────────┴────────────┴──────────────┴──────────────┴───────────────┴─────────────┴──────────────┘"
    
    local total_annual_savings=$(echo "scale=2; $total_monthly_savings * 12" | bc -l)
    
    # In sample mode, extrapolate to full population
    local extrapolated_note=""
    if [[ "$SCAN_MODE" == "sample" ]] && [[ "$account_count" -gt "$SAMPLE_SIZE" ]]; then
        local sample_count=$SAMPLE_SIZE
        local extrapolation_factor=$(echo "scale=4; $account_count / $sample_count" | bc -l)
        
        total_used_gb=$(echo "scale=2; $total_used_gb * $extrapolation_factor" | bc -l)
        total_current_monthly_cost=$(echo "scale=2; $total_current_monthly_cost * $extrapolation_factor" | bc -l)
        total_lrs_monthly_cost=$(echo "scale=2; $total_lrs_monthly_cost * $extrapolation_factor" | bc -l)
        total_monthly_savings=$(echo "scale=2; $total_monthly_savings * $extrapolation_factor" | bc -l)
        total_annual_savings=$(echo "scale=2; $total_annual_savings * $extrapolation_factor" | bc -l)
        
        extrapolated_note="
⚠️  SAMPLE MODE: Analyzed $sample_count of $account_count accounts.
    Values below are EXTRAPOLATED estimates (${extrapolation_factor}x factor).
    Run with SCAN_MODE=full for precise figures."
    fi
    
    # Note for quick mode
    local quick_mode_note=""
    if [[ "$SCAN_MODE" == "quick" ]]; then
        quick_mode_note="
⚠️  QUICK MODE: Storage usage is ESTIMATED based on account types.
    Run with SCAN_MODE=full for actual usage metrics.
    Actual savings may vary significantly."
    fi
    
    local details="GEO-REDUNDANT STORAGE ACCOUNTS - COST SAVINGS ANALYSIS:
$extrapolated_note$quick_mode_note

═══════════════════════════════════════════════════════════════════════════════
SUBSCRIPTION: $subscription_name ($subscription_id)
═══════════════════════════════════════════════════════════════════════════════

SUMMARY:
  • Geo-Redundant Accounts: $account_count
  • Accounts with Usage Data: $accounts_with_usage
  • Accounts without Metrics: $accounts_without_metrics
  • Total Used Capacity: ${total_used_gb} GB ($(echo "scale=2; $total_used_gb / 1024" | bc -l) TB)

COST ANALYSIS:
  • Current Monthly Cost (GRS/RA-GRS): \$$total_current_monthly_cost
  • Projected Monthly Cost (LRS): \$$total_lrs_monthly_cost
  • POTENTIAL MONTHLY SAVINGS: \$$total_monthly_savings
  • POTENTIAL ANNUAL SAVINGS: \$$total_annual_savings

SAVINGS BREAKDOWN BY ACCOUNT:
$savings_table

DETAILED ACCOUNT INVENTORY:
$account_details

REDUNDANCY COST COMPARISON (relative to LRS):
┌────────────────────────────┬──────────────┬──────────────────────┐
│ Redundancy Type            │ Multiplier   │ Description          │
├────────────────────────────┼──────────────┼──────────────────────┤
│ LRS (Locally Redundant)    │ 1.0x         │ 3 copies, 1 region   │
│ ZRS (Zone Redundant)       │ 1.25x        │ 3 zones, 1 region    │
│ GRS (Geo-Redundant)        │ 2.0x         │ 6 copies, 2 regions  │
│ RA-GRS (Read-Access Geo)   │ 2.1x         │ GRS + read secondary │
│ GZRS (Geo-Zone Redundant)  │ 2.5x         │ 3 zones + 3 region2  │
│ RA-GZRS (RA Geo-Zone)      │ 2.6x         │ GZRS + read secondary│
└────────────────────────────┴──────────────┴──────────────────────┘

EVALUATION CRITERIA - When to Downgrade:
✓ Data can be recreated or restored from other sources
✓ Cross-region DR is handled at application level
✓ RPO/RTO requirements don't mandate geo-redundancy
✓ Data is for dev/test/non-critical workloads
✓ Backup/archive data with separate DR strategy

KEEP GRS/GZRS IF:
✗ Regulatory compliance requires geo-redundancy
✗ Data is irreplaceable and mission-critical
✗ Business continuity requires cross-region failover
✗ Healthcare, finance, or legal data retention requirements"

    # Set severity based on potential savings
    local severity=$(get_severity_for_savings "$total_monthly_savings")
    
    local next_steps="ACTIONS - Review and Optimize Storage Redundancy

⚠️  WARNING: Changing redundancy affects data durability. Review carefully.

════════════════════════════════════════════════════════════════════════════════
POTENTIAL MONTHLY SAVINGS: \$$total_monthly_savings
POTENTIAL ANNUAL SAVINGS: \$$total_annual_savings
════════════════════════════════════════════════════════════════════════════════

STEP 1 - CLASSIFY ACCOUNTS BY CRITICALITY:
• Mission-Critical / Compliance-Required → Keep GRS
• Production but app-level DR exists → Consider ZRS
• Dev/Test/Non-Critical → Consider LRS

STEP 2 - VALIDATE BEFORE CHANGING:
Azure Portal:
1. Storage Account → Settings → Configuration
2. Review current Replication setting
3. Check 'Data protection' for recovery options

Azure CLI - Get detailed inventory:
az storage account list --subscription '$subscription_id' \\
  --query \"[?contains(sku.name, 'GRS')].{Name:name, RG:resourceGroup, SKU:sku.name, Location:location, Tier:accessTier}\" -o table

STEP 3 - CHANGE REDUNDANCY (when approved):
# For non-critical accounts:
az storage account update \\
  --name '<account-name>' \\
  --resource-group '<resource-group>' \\
  --sku Standard_LRS \\
  --subscription '$subscription_id'

STEP 4 - VERIFY CHANGE:
az storage account show --name '<account-name>' --query \"sku.name\" -o tsv

RECOMMENDED ROLLOUT:
1. Start with dev/test accounts (lowest risk)
2. Document exceptions for compliance requirements
3. Test redundancy change impact in non-prod
4. Schedule prod changes during maintenance windows
5. Monitor for 30 days post-change

NOTE: If storage metrics show 0 GB usage, the account may have monitoring disabled
or use classic storage APIs. Check Azure Portal for accurate usage."

    add_issue "Geo-Redundant Storage Optimization: $account_count accounts - Save \$$total_monthly_savings/month (\$$total_annual_savings/year)" "$details" "$severity" "$next_steps"
}

# Analysis 5: Find Premium disks with low utilization
analyze_premium_disk_utilization() {
    local subscription_id="$1"
    local subscription_name="$2"
    
    progress "  Checking Premium disks for utilization..."
    
    # Get all Premium disks that are attached
    local premium_disks=$(az disk list --subscription "$subscription_id" \
        --query "[?sku.tier=='Premium' && diskState=='Attached']" -o json 2>/dev/null || echo '[]')
    
    local disk_count=$(echo "$premium_disks" | jq 'length')
    
    if [[ "$disk_count" -eq 0 ]]; then
        progress "  ✓ No attached Premium disks to analyze"
        log "  ✓ No attached Premium disks found"
        return
    fi
    
    progress "  Found $disk_count attached Premium disk(s) - checking IOPS utilization..."
    
    local underutilized_disks=0
    local total_savings=0
    local disk_details=""
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$LOOKBACK_DAYS days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    while IFS= read -r disk_data; do
        local disk_name=$(echo "$disk_data" | jq -r '.name')
        local disk_id=$(echo "$disk_data" | jq -r '.id')
        local disk_rg=$(echo "$disk_data" | jq -r '.resourceGroup')
        local disk_size_gb=$(echo "$disk_data" | jq -r '.diskSizeGb // 0')
        local disk_sku=$(echo "$disk_data" | jq -r '.sku.name')
        local disk_iops=$(echo "$disk_data" | jq -r '.diskIOPSReadWrite // 0')
        local disk_throughput=$(echo "$disk_data" | jq -r '.diskMBpsReadWrite // 0')
        
        # Get disk metrics
        local iops_metrics=$(az monitor metrics list \
            --resource "$disk_id" \
            --metric "Composite Disk Read Operations/sec" "Composite Disk Write Operations/sec" \
            --start-time "$start_time" \
            --end-time "$end_time" \
            --interval PT1H \
            --aggregation Average Maximum \
            -o json 2>/dev/null || echo '{"value":[]}')
        
        # Calculate average and max IOPS
        local avg_read_iops=$(echo "$iops_metrics" | jq -r '.value[0].timeseries[0].data[] | select(.average != null) | .average' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print "0"}')
        local avg_write_iops=$(echo "$iops_metrics" | jq -r '.value[1].timeseries[0].data[] | select(.average != null) | .average' 2>/dev/null | awk '{sum+=$1; count++} END {if(count>0) print sum/count; else print "0"}')
        
        [[ -z "$avg_read_iops" || "$avg_read_iops" == "null" ]] && avg_read_iops="0"
        [[ -z "$avg_write_iops" || "$avg_write_iops" == "null" ]] && avg_write_iops="0"
        
        local total_avg_iops=$(echo "scale=0; $avg_read_iops + $avg_write_iops" | bc -l 2>/dev/null || echo "0")
        
        # Check if disk is underutilized (using less than 20% of provisioned IOPS)
        if [[ "$disk_iops" -gt 0 ]]; then
            local utilization_pct=$(printf "%.0f" "$(echo "scale=4; ($total_avg_iops / $disk_iops) * 100" | bc -l 2>/dev/null)" 2>/dev/null || echo "0")
            
            if [[ "$utilization_pct" -lt 20 ]]; then
                underutilized_disks=$((underutilized_disks + 1))
                
                # Calculate savings if downgraded to Standard SSD
                local premium_cost=$(get_disk_cost "$disk_sku" "$disk_size_gb")
                local standard_cost=$(get_disk_cost "StandardSSD_LRS" "$disk_size_gb")
                local monthly_savings=$(echo "scale=2; $premium_cost - $standard_cost" | bc -l)
                monthly_savings=$(apply_discount "$monthly_savings")
                
                if (( $(echo "$monthly_savings > 0" | bc -l) )); then
                    total_savings=$(echo "scale=2; $total_savings + $monthly_savings" | bc -l)
                    
                    disk_details="${disk_details}
  • $disk_name
    - Resource Group: $disk_rg
    - Size: ${disk_size_gb} GB
    - Current SKU: $disk_sku
    - Provisioned IOPS: $disk_iops
    - Avg IOPS Used: ${total_avg_iops} (${utilization_pct}%)
    - Premium Cost: \$${premium_cost}/month
    - Standard SSD Cost: \$${standard_cost}/month
    - Potential Savings: \$${monthly_savings}/month"
                    
                    log "    • $disk_name (${disk_size_gb}GB, ${utilization_pct}% IOPS) - \$${monthly_savings}/month savings"
                fi
            fi
        fi
    done < <(echo "$premium_disks" | jq -c '.[]')
    
    if [[ $underutilized_disks -gt 0 ]] && (( $(echo "$total_savings > 0" | bc -l) )); then
        local annual_savings=$(echo "scale=2; $total_savings * 12" | bc -l)
        local severity=$(get_severity_for_savings "$total_savings")
        
        local details="UNDERUTILIZED PREMIUM DISKS - DOWNGRADE OPPORTUNITY:

Subscription: $subscription_name ($subscription_id)
Underutilized Premium Disks: $underutilized_disks
Total Monthly Savings: \$$total_savings
Total Annual Savings: \$$annual_savings

UNDERUTILIZED DISKS (IOPS < 20% of provisioned):
$disk_details

ISSUE:
These Premium SSD disks are using less than 20% of their provisioned IOPS.
Premium SSDs are designed for high-performance workloads.
Low utilization suggests Standard SSD would be sufficient.

COMPARISON:
- Premium SSD: High IOPS, low latency, higher cost
- Standard SSD: Moderate IOPS, good latency, lower cost
- Standard HDD: Low IOPS, higher latency, lowest cost

RECOMMENDATION:
Consider downgrading underutilized disks to Standard SSD for significant savings
while maintaining acceptable performance for low-IOPS workloads."

        local next_steps="ACTIONS - Downgrade Underutilized Premium Disks:

⚠️  WARNING: Disk SKU changes require VM to be stopped/deallocated.

Azure Portal:
1. Stop the VM using the disk
2. Go to Disk → Configuration
3. Change 'SKU' from Premium to Standard SSD
4. Start the VM

Azure CLI - Change disk SKU:
# Stop VM first
az vm deallocate --name '<vm-name>' --resource-group '<rg>' --subscription '$subscription_id'

# Update disk SKU
az disk update --name '<disk-name>' --resource-group '<rg>' --sku StandardSSD_LRS --subscription '$subscription_id'

# Start VM
az vm start --name '<vm-name>' --resource-group '<rg>' --subscription '$subscription_id'

RECOMMENDED APPROACH:
1. Test in dev/test environment first
2. Monitor disk performance after change
3. Have rollback plan ready
4. Schedule during maintenance window"

        add_issue "Underutilized Premium Disks: $underutilized_disks disk(s) - \$$total_savings/month savings" "$details" "$severity" "$next_steps"
    else
        progress "  ✓ No underutilized Premium disks found"
        log "  ✓ Premium disks appear to be appropriately utilized"
    fi
}

# Main execution
main() {
    printf "Azure Storage Cost Optimization Analysis — %s\n" "$(date -Iseconds)" > "$REPORT_FILE"
    printf "Analysis Period: Past %s days\n" "$LOOKBACK_DAYS" >> "$REPORT_FILE"
    printf "Snapshot Age Threshold: %s days\n" "$SNAPSHOT_AGE_DAYS" >> "$REPORT_FILE"
    printf "Scan Mode: %s\n" "$SCAN_MODE" >> "$REPORT_FILE"
    if [[ "$DISCOUNT_PERCENTAGE" -gt 0 ]]; then
        printf "Discount Applied: %s%% off MSRP\n" "$DISCOUNT_PERCENTAGE" >> "$REPORT_FILE"
    fi
    hr
    
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   Azure Storage Cost Optimization Analysis                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    progress "🚀 Starting storage optimization analysis at $(date '+%Y-%m-%d %H:%M:%S')"
    progress ""
    
    # Display scan mode
    case "$SCAN_MODE" in
        quick)
            progress "⚡ SCAN MODE: quick (fast, estimates storage usage)"
            progress "   For actual metrics, set SCAN_MODE=full"
            ;;
        full)
            progress "🔍 SCAN MODE: full (detailed, collects actual metrics)"
            progress "   Parallel jobs: $MAX_PARALLEL_JOBS"
            ;;
        sample)
            progress "📊 SCAN MODE: sample (analyzes $SAMPLE_SIZE resources, extrapolates)"
            progress "   For full analysis, set SCAN_MODE=full"
            ;;
    esac
    progress ""
    
    # Check for Resource Graph availability (much faster for large environments)
    USE_RESOURCE_GRAPH="false"
    if check_resource_graph; then
        USE_RESOURCE_GRAPH="true"
        progress "✓ Azure Resource Graph available (10-100x faster queries)"
    else
        progress "⚠️  Resource Graph not available, using standard queries"
    fi
    progress ""
    
    progress "Analysis includes:"
    progress "  • Unattached managed disks"
    progress "  • Old snapshots (>${SNAPSHOT_AGE_DAYS} days)"
    progress "  • Storage accounts without lifecycle policies"
    progress "  • Over-provisioned redundancy (GRS/GZRS)"
    progress "  • Underutilized Premium disks"
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
    local sub_index=0
    for subscription_id in "${SUBSCRIPTIONS[@]}"; do
        subscription_id=$(echo "$subscription_id" | xargs)
        sub_index=$((sub_index + 1))
        
        progress ""
        progress "═══════════════════════════════════════════════════════════════════"
        progress "Subscription [$sub_index/$total_subscriptions]: $subscription_id"
        progress "═══════════════════════════════════════════════════════════════════"
        
        # Set subscription context
        az account set --subscription "$subscription_id" 2>/dev/null || {
            log "❌ Failed to set subscription context for: $subscription_id"
            progress "  ❌ Failed to access subscription"
            continue
        }
        
        local subscription_name=$(az account show --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null || echo "Unknown")
        log ""
        log "═══════════════════════════════════════════════════════════════════"
        log "Subscription: $subscription_name ($subscription_id)"
        log "═══════════════════════════════════════════════════════════════════"
        log ""
        
        # Run all analyses
        analyze_unattached_disks "$subscription_id" "$subscription_name"
        log ""
        
        analyze_old_snapshots "$subscription_id" "$subscription_name"
        log ""
        
        analyze_lifecycle_policies "$subscription_id" "$subscription_name"
        log ""
        
        analyze_redundancy "$subscription_id" "$subscription_name"
        log ""
        
        analyze_premium_disk_utilization "$subscription_id" "$subscription_name"
        log ""
        
        hr
    done
    
    # Finalize issues JSON
    echo "]" >> "$ISSUES_TMP"
    mv "$ISSUES_TMP" "$ISSUES_FILE"
    
    # Generate summary
    local issue_count=$(jq 'length' "$ISSUES_FILE" 2>/dev/null || echo "0")
    
    log ""
    log "╔════════════════════════════════════════════════════════════════════╗"
    log "║   STORAGE ANALYSIS COMPLETE                                        ║"
    log "╚════════════════════════════════════════════════════════════════════╝"
    log ""
    log "Total Storage Optimization Issues Found: $issue_count"
    
    if [[ "$issue_count" -gt 0 ]]; then
        # Extract and display issues by category
        log ""
        log "OPTIMIZATION OPPORTUNITIES:"
        jq -r '.[] | "  • \(.title)"' "$ISSUES_FILE" 2>/dev/null || true
        
        log ""
        log "PRIORITY ACTIONS:"
        log "  1. Delete unattached disks (immediate savings)"
        log "  2. Clean up old snapshots (quick wins)"
        log "  3. Configure lifecycle policies (ongoing savings)"
        log "  4. Review redundancy settings (50% potential savings)"
        log "  5. Downgrade underutilized Premium disks"
    else
        log ""
        log "✅ No storage optimization opportunities found!"
        log "   All storage resources appear to be efficiently managed."
    fi
    
    log ""
    log "Analysis completed at $(date -Iseconds)"
    log "Report saved to: $REPORT_FILE"
    log "Issues JSON saved to: $ISSUES_FILE"
    
    progress ""
    progress "✅ Storage analysis complete!"
    progress "   Issues found: $issue_count"
    progress "   Report: $REPORT_FILE"
    progress "   Issues: $ISSUES_FILE"
}

# Run main function
main "$@"

