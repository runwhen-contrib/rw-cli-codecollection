#!/bin/bash
#
# Azure Performance Utilities Library
# Shared functions for fast resource discovery and parallel processing
# Used by all Azure cost optimization scripts
#
# Usage: source this file at the top of your script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/../../libraries/Azure/azure_performance_utils.sh" 2>/dev/null || \
#   source "/home/runwhen/codecollection/libraries/Azure/azure_performance_utils.sh" 2>/dev/null || true

#=============================================================================
# Configuration (can be overridden by sourcing script)
#=============================================================================
SCAN_MODE=${SCAN_MODE:-full}              # full, quick, or sample
MAX_PARALLEL_JOBS=${MAX_PARALLEL_JOBS:-10}
SAMPLE_SIZE=${SAMPLE_SIZE:-20}
USE_RESOURCE_GRAPH=${USE_RESOURCE_GRAPH:-auto}  # auto, true, or false

# Internal state
_RG_AVAILABLE=""
_PARALLEL_PIDS=()
_METRICS_CACHE_DIR=""

#=============================================================================
# Resource Graph Setup
#=============================================================================

# Check if Resource Graph extension is available and install if needed
azure_perf_init() {
    local temp_dir="${1:-.}"
    _METRICS_CACHE_DIR="$temp_dir/metrics_cache_$$"
    mkdir -p "$_METRICS_CACHE_DIR" 2>/dev/null || true
    
    if [[ "$USE_RESOURCE_GRAPH" == "false" ]]; then
        _RG_AVAILABLE="false"
        return
    fi
    
    if az extension show --name resource-graph &>/dev/null; then
        _RG_AVAILABLE="true"
    else
        echo "📊 Installing Azure Resource Graph extension for faster queries..." >&2
        if az extension add --name resource-graph --yes 2>/dev/null; then
            _RG_AVAILABLE="true"
        else
            echo "⚠️  Resource Graph not available, using standard queries" >&2
            _RG_AVAILABLE="false"
        fi
    fi
    
    if [[ "$_RG_AVAILABLE" == "true" ]]; then
        echo "✓ Azure Resource Graph available (10-100x faster resource discovery)" >&2
    fi
}

# Cleanup function - call this in your trap
azure_perf_cleanup() {
    # Kill any remaining background jobs
    for pid in "${_PARALLEL_PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    _PARALLEL_PIDS=()
    
    # Remove cache directory
    [[ -n "$_METRICS_CACHE_DIR" ]] && rm -rf "$_METRICS_CACHE_DIR" 2>/dev/null || true
}

# Check if Resource Graph is available
is_resource_graph_available() {
    [[ "$_RG_AVAILABLE" == "true" ]]
}

#=============================================================================
# Azure Resource Graph Queries (10-100x faster than az CLI loops)
#=============================================================================

# Generic Resource Graph query
run_resource_graph_query() {
    local subscription_ids="$1"
    local query="$2"
    
    if ! is_resource_graph_available; then
        echo '{"data":[]}'
        return 1
    fi
    
    az graph query -q "$query" --subscriptions "$subscription_ids" --first 1000 -o json 2>/dev/null || echo '{"data":[]}'
}

# Query VMs using Resource Graph
query_vms_graph() {
    local subscription_ids="$1"
    local filter="${2:-}"  # Optional filter like "powerState/running"
    
    local query="Resources
| where type == 'microsoft.compute/virtualmachines'
| extend vmId = tolower(id)
| extend powerState = tostring(properties.extended.instanceView.powerState.code)
| project id, name, resourceGroup, location, 
          vmSize=properties.hardwareProfile.vmSize,
          powerState,
          subscriptionId"
    
    if [[ -n "$filter" ]]; then
        query="$query
| where $filter"
    fi
    
    run_resource_graph_query "$subscription_ids" "$query"
}

# Query AKS clusters using Resource Graph
query_aks_clusters_graph() {
    local subscription_ids="$1"
    
    local query="Resources
| where type == 'microsoft.containerservice/managedclusters'
| project id, name, resourceGroup, location,
          kubernetesVersion=properties.kubernetesVersion,
          nodeResourceGroup=properties.nodeResourceGroup,
          agentPoolProfiles=properties.agentPoolProfiles,
          subscriptionId"
    
    run_resource_graph_query "$subscription_ids" "$query"
}

# Query App Service Plans using Resource Graph
query_appservice_plans_graph() {
    local subscription_ids="$1"
    
    local query="Resources
| where type == 'microsoft.web/serverfarms'
| project id, name, resourceGroup, location,
          skuName=sku.name,
          skuTier=sku.tier,
          skuCapacity=sku.capacity,
          kind=kind,
          workerCount=properties.numberOfWorkers,
          subscriptionId"
    
    run_resource_graph_query "$subscription_ids" "$query"
}

# Query Databricks workspaces using Resource Graph
query_databricks_workspaces_graph() {
    local subscription_ids="$1"
    
    local query="Resources
| where type == 'microsoft.databricks/workspaces'
| project id, name, resourceGroup, location,
          sku=sku.name,
          workspaceUrl=properties.workspaceUrl,
          managedResourceGroupId=properties.managedResourceGroupId,
          subscriptionId"
    
    run_resource_graph_query "$subscription_ids" "$query"
}

# Query unattached disks using Resource Graph
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
    
    run_resource_graph_query "$subscription_ids" "$query"
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
    
    run_resource_graph_query "$subscription_ids" "$query"
}

# Query geo-redundant storage accounts using Resource Graph
query_geo_redundant_storage_graph() {
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
    
    run_resource_graph_query "$subscription_ids" "$query"
}

# Query all storage accounts using Resource Graph
query_storage_accounts_graph() {
    local subscription_ids="$1"
    
    local query="Resources
| where type == 'microsoft.storage/storageaccounts'
| project id, name, resourceGroup, location,
          skuName=sku.name,
          kind=kind,
          accessTier=properties.accessTier,
          subscriptionId"
    
    run_resource_graph_query "$subscription_ids" "$query"
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
    
    run_resource_graph_query "$subscription_ids" "$query"
}

#=============================================================================
# Parallel Processing Utilities
#=============================================================================

# Wait for a slot to open in the parallel job pool
wait_for_parallel_slot() {
    while [[ ${#_PARALLEL_PIDS[@]} -ge $MAX_PARALLEL_JOBS ]]; do
        local new_pids=()
        for pid in "${_PARALLEL_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                new_pids+=("$pid")
            fi
        done
        _PARALLEL_PIDS=("${new_pids[@]}")
        [[ ${#_PARALLEL_PIDS[@]} -ge $MAX_PARALLEL_JOBS ]] && sleep 0.5
    done
}

# Run a command in background with job tracking
run_parallel() {
    local output_file="$1"
    shift
    local cmd="$@"
    
    wait_for_parallel_slot
    
    (eval "$cmd" > "$output_file" 2>/dev/null) &
    _PARALLEL_PIDS+=($!)
}

# Wait for all parallel jobs to complete
wait_all_parallel() {
    for pid in "${_PARALLEL_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    _PARALLEL_PIDS=()
}

# Get cache file path
get_cache_file() {
    local resource_name="$1"
    local metric_type="${2:-metrics}"
    echo "$_METRICS_CACHE_DIR/${resource_name}_${metric_type}.json"
}

#=============================================================================
# Metrics Collection Helpers
#=============================================================================

# Collect Azure Monitor metrics for a resource (can run in parallel)
collect_metrics_for_resource() {
    local resource_id="$1"
    local metric_names="$2"  # Space-separated metric names
    local output_file="$3"
    local lookback_days="${4:-7}"
    local aggregation="${5:-Average Maximum}"
    
    local end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local start_time=$(date -u -d "$lookback_days days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                       date -u -v-${lookback_days}d +"%Y-%m-%dT%H:%M:%SZ")
    
    az monitor metrics list \
        --resource "$resource_id" \
        --metric $metric_names \
        --start-time "$start_time" \
        --end-time "$end_time" \
        --interval PT1H \
        --aggregation $aggregation \
        -o json 2>/dev/null || echo '{}'
}

# Batch collect metrics for multiple resources in parallel
batch_collect_metrics() {
    local resource_ids_json="$1"  # JSON array of {id, name} objects
    local metric_names="$2"
    local lookback_days="${3:-7}"
    
    local count=$(echo "$resource_ids_json" | jq 'length')
    local processed=0
    
    echo "  Collecting metrics for $count resources (parallel, max $MAX_PARALLEL_JOBS jobs)..." >&2
    
    # Use process substitution to avoid subshell variable loss for _PARALLEL_PIDS
    while read -r resource; do
        local resource_id=$(echo "$resource" | jq -r '.id')
        local resource_name=$(echo "$resource" | jq -r '.name')
        local cache_file=$(get_cache_file "$resource_name")
        
        wait_for_parallel_slot
        run_parallel "$cache_file" "collect_metrics_for_resource '$resource_id' '$metric_names' '$cache_file' '$lookback_days'"
        
        processed=$((processed + 1))
        [[ $((processed % 10)) -eq 0 ]] && echo "    Queued $processed/$count..." >&2
    done < <(echo "$resource_ids_json" | jq -c '.[]')
    
    echo "  Waiting for all metrics collection to complete..." >&2
    wait_all_parallel
    echo "  ✓ Metrics collection complete" >&2
}

#=============================================================================
# Sampling Utilities
#=============================================================================

# Generate random sample indices
generate_sample_indices() {
    local total_count="$1"
    local sample_size="${2:-$SAMPLE_SIZE}"
    
    if [[ "$total_count" -le "$sample_size" ]]; then
        seq 0 $((total_count - 1))
    else
        shuf -i 0-$((total_count - 1)) -n "$sample_size" | sort -n
    fi
}

# Check if index is in sample
is_in_sample() {
    local index="$1"
    local sample_indices="$2"  # Space-separated list
    
    echo "$sample_indices" | grep -qw "$index"
}

# Calculate extrapolation factor
get_extrapolation_factor() {
    local total_count="$1"
    local sample_count="$2"
    
    echo "scale=4; $total_count / $sample_count" | bc -l
}

#=============================================================================
# Display Helpers
#=============================================================================

# Print scan mode information
print_scan_mode_info() {
    echo "" >&2
    case "$SCAN_MODE" in
        quick)
            echo "⚡ SCAN MODE: quick" >&2
            echo "   • Resource discovery: Azure Resource Graph (fast)" >&2
            echo "   • Metrics: Estimated based on resource type (no API calls)" >&2
            echo "   For actual metrics, set SCAN_MODE=full" >&2
            ;;
        full)
            echo "🔍 SCAN MODE: full (default)" >&2
            echo "   • Resource discovery: Azure Resource Graph (fast)" >&2
            echo "   • Metrics: Actual Azure Monitor data (parallel, max $MAX_PARALLEL_JOBS jobs)" >&2
            ;;
        sample)
            echo "📊 SCAN MODE: sample" >&2
            echo "   • Resource discovery: Azure Resource Graph (fast)" >&2
            echo "   • Metrics: Collected for $SAMPLE_SIZE resources, extrapolated" >&2
            echo "   For full analysis, set SCAN_MODE=full" >&2
            ;;
    esac
    echo "" >&2
}
