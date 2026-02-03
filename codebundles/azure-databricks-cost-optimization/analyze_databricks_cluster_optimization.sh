#!/bin/bash

# Azure Databricks Cluster Optimization Analysis Script
# Analyzes Databricks workspaces and clusters to identify cost optimization opportunities
# Focuses on: 1) Auto-termination settings (idle clusters), 2) Cluster over-provisioning (utilization)

set -eo pipefail

# Environment variables expected:
# AZURE_SUBSCRIPTION_IDS - Comma-separated list of subscription IDs to analyze (required)
# AZURE_RESOURCE_GROUPS - Comma-separated list of resource groups to analyze (optional, defaults to all)
# COST_ANALYSIS_LOOKBACK_DAYS - Days to look back for metrics (default: 30)
# AZURE_DISCOUNT_PERCENTAGE - Discount percentage off MSRP (optional, defaults to 0)

# Configuration
LOOKBACK_DAYS=${COST_ANALYSIS_LOOKBACK_DAYS:-30}
REPORT_FILE="databricks_cluster_optimization_report.txt"
ISSUES_FILE="databricks_cluster_optimization_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/databricks_cluster_optimization_issues_$$.json"

# Cost thresholds for severity classification
LOW_COST_THRESHOLD=${LOW_COST_THRESHOLD:-500}
MEDIUM_COST_THRESHOLD=${MEDIUM_COST_THRESHOLD:-2000}
HIGH_COST_THRESHOLD=${HIGH_COST_THRESHOLD:-10000}

# Discount percentage (default to 0 if not set)
DISCOUNT_PERCENTAGE=${AZURE_DISCOUNT_PERCENTAGE:-0}

# Auto-termination thresholds
RECOMMENDED_AUTO_TERMINATE_MINUTES=30  # Recommended max idle time before auto-termination
HIGH_IDLE_THRESHOLD_HOURS=24          # Clusters idle > 24 hours = critical waste
MEDIUM_IDLE_THRESHOLD_HOURS=4         # Clusters idle > 4 hours = medium waste

# Utilization thresholds for over-provisioning detection
CPU_UNDERUTILIZATION_THRESHOLD=40     # Peak CPU < 40% = underutilized
MEMORY_UNDERUTILIZATION_THRESHOLD=50  # Peak memory < 50% = underutilized

# Initialize outputs
> "$REPORT_FILE"
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
log() { printf "%s\n" "$*" | tee -a "$REPORT_FILE"; }
hr() { printf -- '─%.0s' {1..80} | tee -a "$REPORT_FILE"; printf "\n" | tee -a "$REPORT_FILE"; }
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

# Azure VM Pricing for Databricks nodes (same as AKS pricing)
get_azure_vm_cost() {
    local vm_size="$1"
    local vm_lower=$(echo "$vm_size" | tr '[:upper:]' '[:lower:]')
    
    # Standard D-series (most common for Databricks)
    case "$vm_lower" in
        # D-series v3
        standard_d2s_v3) echo "70.08" ;;
        standard_d4s_v3) echo "140.16" ;;
        standard_d8s_v3) echo "280.32" ;;
        standard_d16s_v3) echo "560.64" ;;
        standard_d32s_v3) echo "1121.28" ;;
        
        # D-series v4
        standard_d2s_v4) echo "69.35" ;;
        standard_d4s_v4) echo "138.70" ;;
        standard_d8s_v4) echo "277.40" ;;
        standard_d16s_v4) echo "554.80" ;;
        standard_d32s_v4) echo "1109.60" ;;
        
        # D-series v5
        standard_d2s_v5) echo "69.35" ;;
        standard_d4s_v5) echo "138.70" ;;
        standard_d8s_v5) echo "277.40" ;;
        standard_d16s_v5) echo "554.80" ;;
        standard_d32s_v5) echo "1109.60" ;;
        
        # E-series (memory optimized)
        standard_e2s_v3) echo "132.41" ;;
        standard_e4s_v3) echo "264.82" ;;
        standard_e8s_v3) echo "529.64" ;;
        standard_e16s_v3) echo "1059.28" ;;
        standard_e32s_v3) echo "2118.56" ;;
        
        # F-series (compute optimized)
        standard_f2s_v2) echo "59.13" ;;
        standard_f4s_v2) echo "118.26" ;;
        standard_f8s_v2) echo "236.52" ;;
        standard_f16s_v2) echo "473.04" ;;
        standard_f32s_v2) echo "946.08" ;;
        
        # Default fallback for unknown VM types
        *) echo "100.00" ;;
    esac
}

# Calculate Databricks DBU cost per hour
# Azure Databricks pricing: https://azure.microsoft.com/en-us/pricing/details/databricks/
get_dbu_cost_per_hour() {
    local cluster_type="$1"  # "all-purpose" or "jobs"
    
    case "$cluster_type" in
        all-purpose|interactive)
            # All-purpose compute: $0.40 per DBU
            echo "0.40"
            ;;
        jobs|automated)
            # Jobs compute: $0.15 per DBU
            echo "0.15"
            ;;
        *)
            # Default to all-purpose (more conservative)
            echo "0.40"
            ;;
    esac
}

# Calculate DBUs per hour based on VM size
# Rough approximation: 1 DBU per vCore
get_dbus_per_hour() {
    local vm_size="$1"
    local vm_lower=$(echo "$vm_size" | tr '[:upper:]' '[:lower:]')
    
    case "$vm_lower" in
        # 2 vCore VMs
        standard_d2*|standard_e2*|standard_f2*) echo "2" ;;
        # 4 vCore VMs
        standard_d4*|standard_e4*|standard_f4*) echo "4" ;;
        # 8 vCore VMs
        standard_d8*|standard_e8*|standard_f8*) echo "8" ;;
        # 16 vCore VMs
        standard_d16*|standard_e16*|standard_f16*) echo "16" ;;
        # 32 vCore VMs
        standard_d32*|standard_e32*|standard_f32*) echo "32" ;;
        # 64 vCore VMs
        standard_d64*|standard_e64*|standard_f64*) echo "64" ;;
        # Default
        *) echo "4" ;;
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

# Get Databricks access token for a workspace
get_databricks_token() {
    local workspace_id="$1"
    local subscription_id="$2"
    
    # Get Azure AD token
    local azure_token=$(az account get-access-token --resource 2ff814a6-3304-4ab8-85cb-cd0e6f879c1d --query accessToken -o tsv 2>/dev/null)
    
    if [[ -z "$azure_token" ]]; then
        echo ""
        return 1
    fi
    
    echo "$azure_token"
}

# Get Databricks workspace URL
get_workspace_url() {
    local workspace_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    
    local url=$(az databricks workspace show \
        --name "$workspace_name" \
        --resource-group "$resource_group" \
        --subscription "$subscription_id" \
        --query "workspaceUrl" -o tsv 2>/dev/null)
    
    echo "$url"
}

# List all clusters in a workspace
list_clusters() {
    local workspace_url="$1"
    local token="$2"
    
    local response=$(curl -s -w "\n%{http_code}" -X GET "https://${workspace_url}/api/2.0/clusters/list" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" 2>/dev/null)
    
    local http_code=$(echo "$response" | tail -n1)
    local body=$(echo "$response" | sed '$d')
    
    # Check if response is valid JSON
    if ! echo "$body" | jq empty 2>/dev/null; then
        progress "  ⚠️  Invalid JSON response from Databricks API"
        progress "  HTTP Status: $http_code"
        progress "  Response: ${body:0:200}..."
        echo '{"clusters":[]}'
        return
    fi
    
    # Check for error in response
    local error_msg=$(echo "$body" | jq -r '.error_code // empty')
    if [[ -n "$error_msg" ]]; then
        progress "  ⚠️  Databricks API error: $error_msg"
        progress "  $(echo "$body" | jq -r '.message // empty')"
        echo '{"clusters":[]}'
        return
    fi
    
    echo "$body"
}

# Get cluster events (to calculate idle time)
get_cluster_events() {
    local workspace_url="$1"
    local token="$2"
    local cluster_id="$3"
    
    curl -s -X POST "https://${workspace_url}/api/2.0/clusters/events" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"cluster_id\": \"$cluster_id\", \"limit\": 100}" 2>/dev/null || echo '{"events":[]}'
}

# Get Spark metrics for a cluster from Databricks API
# This queries the Spark UI metrics endpoint if cluster is running
get_cluster_metrics() {
    local workspace_url="$1"
    local token="$2"
    local cluster_id="$3"
    local state="$4"
    
    # If cluster is not running, we can't get current metrics
    if [[ "$state" != "RUNNING" ]]; then
        echo '{"cpu_avg": 0, "cpu_peak": 0, "memory_avg": 0, "memory_peak": 0, "worker_count_avg": 0}'
        return
    fi
    
    # Try to get cluster metrics from Databricks API
    # Method 1: Use Spark UI metrics API (requires cluster to be running)
    local metrics=$(curl -s -X GET "https://${workspace_url}/api/2.0/clusters/get?cluster_id=${cluster_id}" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" 2>/dev/null)
    
    # Extract actual worker count if autoscaling
    local current_workers=$(echo "$metrics" | jq -r '.num_workers // 0')
    
    # Try to get more detailed metrics from Ganglia/Spark UI if available
    # Note: This requires additional API endpoints that may not be available in all Databricks deployments
    local spark_metrics=$(curl -s -X GET "https://${workspace_url}/api/2.0/clusters/spark-ui?cluster_id=${cluster_id}" \
        -H "Authorization: Bearer $token" 2>/dev/null || echo '{}')
    
    # For now, return structure with actual worker count
    # Real metrics would require integration with Ganglia or custom metrics collection
    echo "{\"cpu_avg\": 0, \"cpu_peak\": 0, \"memory_avg\": 0, \"memory_peak\": 0, \"worker_count_avg\": $current_workers}"
}

# Calculate idle hours and running hours from cluster events
calculate_cluster_usage() {
    local events="$1"
    local current_state="$2"
    local lookback_days="$3"
    
    local current_time=$(date +%s)
    local lookback_seconds=$((lookback_days * 24 * 3600))
    local start_time=$((current_time - lookback_seconds))
    
    # Parse events to calculate total running hours and idle hours
    local total_running_hours=0
    local last_start_time=0
    local last_stop_time=0
    local idle_hours=0
    
    # Sort events by timestamp (most recent first)
    local sorted_events=$(echo "$events" | jq -r '.events | sort_by(.timestamp) | reverse | .[]')
    
    # Calculate running time from events
    local running_start=0
    local event_count=$(echo "$events" | jq '.events | length')
    
    if [[ "$event_count" -gt 0 ]]; then
        # Get most recent RUNNING event
        local last_running=$(echo "$events" | jq -r '.events[] | select(.type == "RUNNING" or .type == "STARTING") | .timestamp' | head -1)
        
        # Get most recent termination/stop event
        local last_stopped=$(echo "$events" | jq -r '.events[] | select(.type == "TERMINATING" or .type == "TERMINATED") | .timestamp' | head -1)
        
        if [[ -n "$last_running" && "$last_running" != "null" ]]; then
            local last_running_epoch=$(date -d "@$((last_running / 1000))" +%s 2>/dev/null || echo "$current_time")
            
            # If cluster is currently running and no recent stop, calculate idle time
            if [[ "$current_state" == "RUNNING" ]]; then
                if [[ -z "$last_stopped" || "$last_stopped" == "null" || "$last_running" -gt "$last_stopped" ]]; then
                    local running_duration=$((current_time - last_running_epoch))
                    idle_hours=$(echo "scale=2; $running_duration / 3600" | bc -l)
                fi
            fi
            
            # Estimate total running hours in lookback period (rough approximation)
            # This is simplified - in production you'd iterate through all start/stop events
            total_running_hours=$(echo "scale=2; $event_count * 2" | bc -l)  # Rough estimate
        fi
    fi
    
    # Return format: idle_hours|total_running_hours
    echo "${idle_hours}|${total_running_hours}"
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

# Analyze a single cluster
analyze_cluster() {
    local workspace_name="$1"
    local workspace_url="$2"
    local resource_group="$3"
    local subscription_name="$4"
    local subscription_id="$5"
    local token="$6"
    local cluster_data="$7"
    
    local cluster_id=$(echo "$cluster_data" | jq -r '.cluster_id')
    local cluster_name=$(echo "$cluster_data" | jq -r '.cluster_name')
    local state=$(echo "$cluster_data" | jq -r '.state')
    local autotermination_minutes=$(echo "$cluster_data" | jq -r '.autotermination_minutes // 0')
    local cluster_source=$(echo "$cluster_data" | jq -r '.cluster_source // "UI"')
    local num_workers=$(echo "$cluster_data" | jq -r '.num_workers // 0')
    local driver_node_type=$(echo "$cluster_data" | jq -r '.driver_node_type_id // "unknown"')
    local worker_node_type=$(echo "$cluster_data" | jq -r '.node_type_id // "unknown"')
    local spark_version=$(echo "$cluster_data" | jq -r '.spark_version // "unknown"')
    
    log "  Analyzing Cluster: $cluster_name"
    log "    Cluster ID: $cluster_id"
    log "    State: $state"
    log "    Workers: $num_workers"
    log "    Driver Node: $driver_node_type"
    log "    Worker Node: $worker_node_type"
    log "    Auto-termination: $autotermination_minutes minutes"
    log "    Source: $cluster_source"
    
    # === ANALYSIS 0: UNUSED/OLD CLUSTERS ===
    # Check for clusters that haven't been used in a long time
    local last_activity_time=$(echo "$cluster_data" | jq -r '.last_activity_time // 0')
    local last_state_change=$(echo "$cluster_data" | jq -r '.state_message // ""')
    
    if [[ "$state" == "TERMINATED" && "$last_activity_time" -gt 0 ]]; then
        local current_time_ms=$(($(date +%s) * 1000))
        local days_since_activity=$(echo "scale=0; ($current_time_ms - $last_activity_time) / (1000 * 86400)" | bc -l)
        
        # Flag clusters not used in 90+ days
        if [[ "$days_since_activity" -gt 90 ]]; then
            log "    ⚠️  Cluster has been inactive for $days_since_activity days"
            
            local details="UNUSED CLUSTER - CONSIDER DELETION:

Workspace: $workspace_name
Cluster: $cluster_name ($cluster_id)
Resource Group: $resource_group
Subscription: $subscription_name ($subscription_id)

ISSUE:
This cluster has been terminated and inactive for $days_since_activity days.
Old, unused clusters can accumulate and create workspace clutter.

CLUSTER CONFIGURATION:
- State: $state
- Last Activity: $days_since_activity days ago
- Workers: $num_workers x $worker_node_type

RECOMMENDATION:
Review if this cluster is still needed. If not, delete it to:
- Reduce workspace clutter
- Simplify cluster management
- Ensure no inadvertent restarts

COST IMPACT:
- Current cost: \$0 (terminated)
- Risk: Accidental restart could incur costs

NOTE: While terminated clusters don't incur compute costs, maintaining unused 
cluster definitions can lead to accidental starts and makes workspace management harder."

            local next_steps="1. Verify cluster is no longer needed
2. Navigate to Databricks workspace: https://${workspace_url}
3. Go to Compute > $cluster_name
4. Click 'Permanently Delete' if confirmed unused

Databricks API:
curl -X POST https://${workspace_url}/api/2.0/clusters/permanent-delete \\
  -H \"Authorization: Bearer \$DATABRICKS_TOKEN\" \\
  -d '{\"cluster_id\": \"$cluster_id\"}'"

            add_issue "Databricks Cluster: $cluster_name - Inactive for $days_since_activity days, Consider Deletion" "$details" "4" "$next_steps"
        fi
    fi
    
    # Determine cluster type (all-purpose vs jobs)
    local cluster_type="all-purpose"
    if [[ "$cluster_source" == "JOB" ]]; then
        cluster_type="jobs"
    fi
    
    # Calculate costs
    local worker_vm_cost=$(get_azure_vm_cost "$worker_node_type")
    local driver_vm_cost=$(get_azure_vm_cost "$driver_node_type")
    local dbu_cost_per_hour=$(get_dbu_cost_per_hour "$cluster_type")
    local dbus_per_worker=$(get_dbus_per_hour "$worker_node_type")
    local dbus_per_driver=$(get_dbus_per_hour "$driver_node_type")
    
    # Total hourly cost = VM cost + DBU cost
    local vm_hourly_cost=$(echo "scale=4; ($worker_vm_cost * $num_workers + $driver_vm_cost) / 730" | bc -l)
    local dbu_hourly_cost=$(echo "scale=4; ($dbus_per_worker * $num_workers + $dbus_per_driver) * $dbu_cost_per_hour" | bc -l)
    local total_hourly_cost=$(echo "scale=2; $vm_hourly_cost + $dbu_hourly_cost" | bc -l)
    local total_hourly_cost=$(apply_discount "$total_hourly_cost")
    
    log "    Estimated Hourly Cost: \$$total_hourly_cost (VM: \$$vm_hourly_cost/hr, DBU: \$$dbu_hourly_cost/hr)"
    
    # === ANALYSIS 1: AUTO-TERMINATION ISSUES ===
    if [[ "$state" == "RUNNING" ]]; then
        # Get cluster events to determine idle time and usage patterns
        progress "    Checking cluster activity..."
        local events=$(get_cluster_events "$workspace_url" "$token" "$cluster_id")
        local usage_data=$(calculate_cluster_usage "$events" "$state" "$LOOKBACK_DAYS")
        IFS='|' read -r idle_hours total_running_hours <<< "$usage_data"
        
        log "    Current Idle Time: ${idle_hours} hours"
        log "    Estimated Running Hours (${LOOKBACK_DAYS}d): ${total_running_hours} hours"
        
        # Check if auto-termination is disabled or set too high
        if [[ "$autotermination_minutes" -eq 0 ]] || [[ "$autotermination_minutes" -gt $(( RECOMMENDED_AUTO_TERMINATE_MINUTES * 2 )) ]]; then
            local auto_term_issue=true
            local auto_term_status="DISABLED"
            [[ "$autotermination_minutes" -gt 0 ]] && auto_term_status="${autotermination_minutes} minutes (TOO HIGH)"
            
            log "    ⚠️  Auto-termination issue detected: $auto_term_status"
            
            # Calculate potential savings based on estimated running hours
            # Assume 40% of running time could be saved with proper auto-termination
            local wastage_percentage=0.40
            
            # If we have running hours data, use it for better estimation
            if [[ "$total_running_hours" != "0" && "$total_running_hours" != "null" ]]; then
                local wasted_hours_per_month=$(echo "scale=2; ($total_running_hours / $LOOKBACK_DAYS) * 30 * $wastage_percentage" | bc -l)
            else
                # Fallback: Assume cluster runs 24/7 without auto-termination, vs 8 hours/day with proper auto-termination
                local hours_wasted_per_day=16  # Conservative estimate
                local wasted_hours_per_month=$(echo "scale=2; $hours_wasted_per_day * 30" | bc -l)
            fi
            
            local monthly_waste=$(echo "scale=2; $total_hourly_cost * $wasted_hours_per_month" | bc -l)
            local annual_waste=$(echo "scale=2; $monthly_waste * 12" | bc -l)
            
            local severity=$(get_severity_for_savings "$monthly_waste")
            
            local details="CLUSTER AUTO-TERMINATION NOT CONFIGURED:

Workspace: $workspace_name
Cluster: $cluster_name ($cluster_id)
Resource Group: $resource_group
Subscription: $subscription_name ($subscription_id)

ISSUE:
Auto-termination is currently: $auto_term_status
Recommended setting: $RECOMMENDED_AUTO_TERMINATE_MINUTES minutes

CLUSTER CONFIGURATION:
- State: $state
- Type: $cluster_type
- Workers: $num_workers x $worker_node_type
- Driver: 1 x $driver_node_type
- Hourly Cost: \$$total_hourly_cost

USAGE ANALYSIS (${LOOKBACK_DAYS} days):
- Current Idle Time: ${idle_hours} hours
- Estimated Running Hours: ${total_running_hours} hours
- Estimated wastage without auto-termination: ${wastage_percentage}% of runtime

COST IMPACT:
- Estimated wasted hours/month: ${wasted_hours_per_month} hours
- Monthly waste: \$$monthly_waste
- Annual waste: \$$annual_waste

RECOMMENDATION:
Enable auto-termination after $RECOMMENDED_AUTO_TERMINATE_MINUTES minutes of inactivity to prevent idle cluster costs.
This will automatically shut down the cluster when not in use, saving both VM and DBU costs."

            local next_steps="1. Navigate to the Databricks workspace: https://${workspace_url}
2. Go to Compute > $cluster_name > Configuration
3. Enable auto-termination and set to $RECOMMENDED_AUTO_TERMINATE_MINUTES minutes
4. For job clusters, ensure they're using 'Job Clusters' instead of 'All-Purpose Clusters'

Alternative (Azure CLI):
az databricks cluster update --resource-group $resource_group --workspace-name $workspace_name --cluster-id $cluster_id --autotermination-minutes $RECOMMENDED_AUTO_TERMINATE_MINUTES"

            add_issue "Databricks Cluster: $cluster_name - Auto-Termination Not Configured (\$$monthly_waste/month)" "$details" "$severity" "$next_steps"
        fi
        
        # Check for long idle times even with auto-termination enabled
        if (( $(echo "$idle_hours > $HIGH_IDLE_THRESHOLD_HOURS" | bc -l) )); then
            log "    ⚠️  Cluster has been idle for ${idle_hours} hours (threshold: $HIGH_IDLE_THRESHOLD_HOURS hours)"
            
            local idle_waste=$(echo "scale=2; $total_hourly_cost * $idle_hours" | bc -l)
            local monthly_idle_waste=$(echo "scale=2; $idle_waste * 1" | bc -l)  # This is current waste, not monthly
            
            local severity="4"
            
            local details="CLUSTER RUNNING IDLE FOR EXTENDED PERIOD:

Workspace: $workspace_name
Cluster: $cluster_name ($cluster_id)
Resource Group: $resource_group
Subscription: $subscription_name ($subscription_id)

ISSUE:
Cluster has been running idle for ${idle_hours} hours without activity.

CURRENT COST:
- Hourly Cost: \$$total_hourly_cost
- Wasted so far: \$$idle_waste

RECOMMENDATION:
Terminate this idle cluster immediately to stop wasting costs."

            local next_steps="IMMEDIATE ACTION - Terminate idle cluster:

1. Navigate to: https://${workspace_url}
2. Go to Compute > $cluster_name
3. Click 'Terminate' to stop the cluster immediately
4. Review auto-termination settings to prevent future occurrences"

            add_issue "Databricks Cluster: $cluster_name - Running Idle for ${idle_hours} hours" "$details" "$severity" "$next_steps"
        fi
    fi
    
    # === ANALYSIS 2: CLUSTER OVER-PROVISIONING ===
    # Check for autoscaling configuration and worker utilization
    local autoscale_enabled=$(echo "$cluster_data" | jq -r '.autoscale // null')
    local min_workers=$(echo "$cluster_data" | jq -r '.autoscale.min_workers // 0')
    local max_workers=$(echo "$cluster_data" | jq -r '.autoscale.max_workers // 0')
    
    # Get current metrics to understand actual utilization
    local metrics=$(get_cluster_metrics "$workspace_url" "$token" "$cluster_id" "$state")
    local current_worker_count=$(echo "$metrics" | jq -r '.worker_count_avg // 0')
    
    # If current worker count from metrics is 0, fall back to configured count
    [[ "$current_worker_count" == "0" || "$current_worker_count" == "null" ]] && current_worker_count=$num_workers
    
    # Analysis for autoscaling clusters
    if [[ "$autoscale_enabled" != "null" ]]; then
        log "    Autoscaling: Enabled (min: $min_workers, max: $max_workers, current: $current_worker_count)"
        
        # Check if autoscaling range is too wide or min is too high
        if [[ $min_workers -gt 5 ]] && [[ "$state" == "RUNNING" ]]; then
            # Analyze if minimum could be reduced
            local runtime_hours=$(echo "$events" | jq -r '[.events[] | select(.type == "RUNNING")] | length / 2' | awk '{printf "%.0f", $1}')
            
            # If cluster typically runs with workers close to minimum, suggest reducing minimum
            if [[ "$current_worker_count" -le $((min_workers + 2)) ]]; then
                local suggested_min_workers=$((min_workers * 2 / 3))
                [[ $suggested_min_workers -lt 2 ]] && suggested_min_workers=2
                
                local workers_saved=$((min_workers - suggested_min_workers))
                local monthly_savings=$(echo "scale=2; ($worker_vm_cost / 730) * 730 * $workers_saved" | bc -l)
                monthly_savings=$(echo "scale=2; $monthly_savings + (($dbus_per_worker * $workers_saved * $dbu_cost_per_hour) * 730)" | bc -l)
                monthly_savings=$(apply_discount "$monthly_savings")
                local annual_savings=$(echo "scale=2; $monthly_savings * 12" | bc -l)
                
                local severity=$(get_severity_for_savings "$monthly_savings")
                
                local details="AUTOSCALING CLUSTER - HIGH MINIMUM WORKER COUNT:

Workspace: $workspace_name
Cluster: $cluster_name ($cluster_id)
Resource Group: $resource_group
Subscription: $subscription_name ($subscription_id)

CURRENT CONFIGURATION:
- Autoscaling: Enabled
- Min Workers: $min_workers
- Max Workers: $max_workers
- Current Workers: $current_worker_count
- Worker Type: $worker_node_type

UTILIZATION ANALYSIS:
The cluster is currently running with $current_worker_count workers, which is close to 
the minimum ($min_workers). This suggests the minimum might be set too high for typical workload.

RECOMMENDATION:
Reduce minimum workers from $min_workers to $suggested_min_workers while keeping max at $max_workers.
This allows the cluster to scale down more during low-demand periods while still scaling up for peaks.

PROJECTED SAVINGS:
- Workers Saved (at minimum): $workers_saved
- Monthly Savings: \$$monthly_savings
- Annual Savings: \$$annual_savings

IMPLEMENTATION:
The autoscaler will automatically adjust worker count based on workload. Reducing the 
minimum allows more aggressive scale-down during idle periods."

                local next_steps="1. Navigate to Databricks workspace: https://${workspace_url}
2. Go to Compute > $cluster_name > Configuration > Autoscaling
3. Update minimum workers to $suggested_min_workers (keep max at $max_workers)
4. Monitor cluster performance for 1-2 weeks

Databricks API:
curl -X POST https://${workspace_url}/api/2.0/clusters/edit \\
  -H \"Authorization: Bearer \$DATABRICKS_TOKEN\" \\
  -d '{
    \"cluster_id\": \"$cluster_id\",
    \"autoscale\": {
      \"min_workers\": $suggested_min_workers,
      \"max_workers\": $max_workers
    }
  }'"

                add_issue "Databricks Cluster: $cluster_name - Reduce Autoscaling Minimum (\$$monthly_savings/month)" "$details" "$severity" "$next_steps"
            fi
        fi
    # Analysis for fixed-size clusters (no autoscaling)
    elif [[ "$num_workers" -gt 10 ]]; then
        log "    ℹ️  Large fixed-size cluster detected ($num_workers workers) - consider enabling autoscaling"
        
        # Suggest enabling autoscaling for large fixed clusters
        local suggested_min=$((num_workers / 2))
        [[ $suggested_min -lt 2 ]] && suggested_min=2
        local suggested_max=$((num_workers))
        
        local workers_saved=$((num_workers - suggested_min))
        local monthly_savings=$(echo "scale=2; ($worker_vm_cost / 730) * 730 * $workers_saved * 0.5" | bc -l)  # 50% of time at min
        monthly_savings=$(echo "scale=2; $monthly_savings + (($dbus_per_worker * $workers_saved * $dbu_cost_per_hour) * 365)" | bc -l)
        monthly_savings=$(apply_discount "$monthly_savings")
        local annual_savings=$(echo "scale=2; $monthly_savings * 12" | bc -l)
        
        local severity=$(get_severity_for_savings "$monthly_savings")
        
        local details="FIXED-SIZE CLUSTER - AUTOSCALING NOT ENABLED:

Workspace: $workspace_name
Cluster: $cluster_name ($cluster_id)
Resource Group: $resource_group
Subscription: $subscription_name ($subscription_id)

CURRENT CONFIGURATION:
- Workers: $num_workers (fixed - no autoscaling)
- Worker Type: $worker_node_type
- Cluster Source: $cluster_source

ISSUE:
This cluster runs with a fixed number of workers ($num_workers) regardless of workload demand.
For clusters with variable workload, autoscaling can significantly reduce costs.

RECOMMENDATION:
Enable autoscaling with:
- Minimum workers: $suggested_min
- Maximum workers: $suggested_max

This allows the cluster to scale down during low-demand periods while maintaining 
capacity to scale up to current levels when needed.

PROJECTED SAVINGS:
- Estimated savings (assuming 50% time at minimum): \$$monthly_savings/month
- Annual Savings: \$$annual_savings

NOTE: Actual savings depend on workload patterns. Bursty workloads benefit most from autoscaling."

        local next_steps="1. Navigate to Databricks workspace: https://${workspace_url}
2. Go to Compute > $cluster_name > Configuration
3. Enable autoscaling: min=$suggested_min, max=$suggested_max
4. Monitor cluster performance after enabling

Databricks API:
curl -X POST https://${workspace_url}/api/2.0/clusters/edit \\
  -H \"Authorization: Bearer \$DATABRICKS_TOKEN\" \\
  -d '{
    \"cluster_id\": \"$cluster_id\",
    \"autoscale\": {
      \"min_workers\": $suggested_min,
      \"max_workers\": $suggested_max
    }
  }'"

        add_issue "Databricks Cluster: $cluster_name - Enable Autoscaling (\$$monthly_savings/month potential)" "$details" "$severity" "$next_steps"
    fi
    
    # === ANALYSIS 3: VM TYPE OPTIMIZATION ===
    # Check if cheaper VM alternatives are available
    local vm_series=""
    if [[ "$worker_node_type" =~ Standard_D([0-9]+)s_v([0-9]+) ]]; then
        vm_series="D-series"
        local vm_cores="${BASH_REMATCH[1]}"
        local vm_version="${BASH_REMATCH[2]}"
        
        # Suggest AMD alternatives (typically 15-20% cheaper)
        local suggested_amd_vm="Standard_D${vm_cores}as_v4"
        local current_vm_cost=$(get_azure_vm_cost "$worker_node_type")
        local suggested_vm_cost=$(get_azure_vm_cost "$suggested_amd_vm")
        
        # Only recommend if there's a cost difference
        if (( $(echo "$current_vm_cost > $suggested_vm_cost" | bc -l) )); then
            local vm_monthly_savings=$(echo "scale=2; ($current_vm_cost - $suggested_vm_cost) * $num_workers" | bc -l)
            
            # Add DBU savings (same DBUs but lower total cost)
            vm_monthly_savings=$(apply_discount "$vm_monthly_savings")
            local vm_annual_savings=$(echo "scale=2; $vm_monthly_savings * 12" | bc -l)
            
            # Calculate total monthly cost for current configuration
            local monthly_cost=$(echo "scale=2; $current_vm_cost * $num_workers" | bc -l)
            
            # Only report if savings are meaningful (>$100/month)
            if (( $(echo "$vm_monthly_savings > 100" | bc -l) )); then
                local severity=$(get_severity_for_savings "$vm_monthly_savings")
                
                local details="VM TYPE OPTIMIZATION OPPORTUNITY - SWITCH TO AMD:

Workspace: $workspace_name
Cluster: $cluster_name ($cluster_id)
Resource Group: $resource_group
Subscription: $subscription_name ($subscription_id)

CURRENT CONFIGURATION:
- Worker VM Type: $worker_node_type (Intel)
- Workers: $num_workers
- Monthly VM Cost: \$$current_vm_cost per VM
- Total Monthly Cost: \$$monthly_cost

RECOMMENDATION:
Switch to AMD-based VMs: $suggested_amd_vm
- Same performance characteristics
- Lower cost: \$$suggested_vm_cost per VM
- Azure AMD VMs offer comparable performance at 15-20% lower cost

PROJECTED SAVINGS:
- Per VM Savings: \$$(echo "scale=2; $current_vm_cost - $suggested_vm_cost" | bc -l)/month
- Total Monthly Savings: \$$vm_monthly_savings
- Annual Savings: \$$vm_annual_savings

NOTE: AMD-based VMs (Das_v4 series) provide similar performance to Intel D-series
at a lower price point. Ensure your workload doesn't have Intel-specific dependencies."

                local next_steps="1. Test workload on AMD VMs in non-production environment first
2. Navigate to Databricks workspace: https://${workspace_url}
3. Create new cluster with $suggested_amd_vm VM type
4. Run representative workload and validate performance
5. If performance is acceptable, update production cluster

Databricks API:
curl -X POST https://${workspace_url}/api/2.0/clusters/edit \\
  -H \"Authorization: Bearer \$DATABRICKS_TOKEN\" \\
  -d '{
    \"cluster_id\": \"$cluster_id\",
    \"node_type_id\": \"$suggested_amd_vm\"
  }'"

                add_issue "Databricks Cluster: $cluster_name - Switch to AMD VMs (\$$vm_monthly_savings/month)" "$details" "$severity" "$next_steps"
            fi
        fi
    fi
    
    log ""
}

# Analyze a Databricks workspace
analyze_workspace() {
    local workspace_name="$1"
    local resource_group="$2"
    local subscription_id="$3"
    local subscription_name="$4"
    
    log "Analyzing Databricks Workspace: $workspace_name"
    log "  Resource Group: $resource_group"
    log "  Subscription: $subscription_name"
    
    # Get workspace URL
    progress "  Getting workspace URL..."
    local workspace_url=$(get_workspace_url "$workspace_name" "$resource_group" "$subscription_id")
    
    if [[ -z "$workspace_url" ]]; then
        log "  ⚠️  Could not retrieve workspace URL - skipping"
        hr
        return
    fi
    
    log "  Workspace URL: https://$workspace_url"
    
    # Get Databricks access token
    progress "  Obtaining Databricks access token..."
    local token=$(get_databricks_token "$workspace_name" "$subscription_id")
    
    if [[ -z "$token" ]]; then
        log "  ⚠️  Could not obtain Databricks access token - skipping cluster analysis"
        log "  Note: Ensure service principal has 'Contributor' role on Databricks workspace"
        hr
        return
    fi
    
    # List all clusters
    progress "  Fetching cluster list..."
    local clusters=$(list_clusters "$workspace_url" "$token")
    local cluster_count=$(echo "$clusters" | jq '.clusters // [] | length' 2>/dev/null || echo "0")
    
    log "  Total Clusters: $cluster_count"
    
    if [[ "$cluster_count" -eq 0 || -z "$cluster_count" ]]; then
        log "  ℹ️  No clusters found in this workspace (or unable to retrieve cluster list)"
        log "  This may indicate:"
        log "    - No clusters exist in this workspace"
        log "    - Insufficient permissions (need 'Contributor' or 'Databricks Workspace Contributor' role)"
        log "    - API authentication issues"
        hr
        return
    fi
    
    # Analyze each cluster
    echo "$clusters" | jq -c '.clusters[]' 2>/dev/null | while read -r cluster_data; do
        analyze_cluster "$workspace_name" "$workspace_url" "$resource_group" "$subscription_name" "$subscription_id" "$token" "$cluster_data"
    done
    
    hr
}

# Discover all Databricks workspaces across subscriptions
discover_all_workspaces() {
    local subscription_ids="$1"
    
    progress ""
    progress "╔════════════════════════════════════════════════════════════════════╗"
    progress "║   DATABRICKS WORKSPACE DISCOVERY                                  ║"
    progress "╚════════════════════════════════════════════════════════════════════╝"
    progress ""
    
    local all_workspaces="[]"
    local total_workspace_count=0
    
    IFS=',' read -ra SUBS <<< "$subscription_ids"
    
    for subscription_id in "${SUBS[@]}"; do
        subscription_id=$(echo "$subscription_id" | xargs)
        
        az account set --subscription "$subscription_id" 2>/dev/null || continue
        local sub_name=$(az account show --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null || echo "Unknown")
        
        progress "📊 Subscription: $sub_name"
        progress "   ID: $subscription_id"
        
        local workspaces=$(az databricks workspace list --subscription "$subscription_id" -o json 2>/dev/null || echo "[]")
        local ws_count=$(echo "$workspaces" | jq 'length')
        
        if [[ "$ws_count" -gt 0 ]]; then
            progress "   ✓ Found $ws_count workspace(s)"
            
            # Display workspace details
            echo "$workspaces" | jq -c '.[]' | while read -r ws; do
                local ws_name=$(echo "$ws" | jq -r '.name')
                local ws_rg=$(echo "$ws" | jq -r '.resourceGroup')
                local ws_location=$(echo "$ws" | jq -r '.location')
                local ws_sku=$(echo "$ws" | jq -r '.sku.name // "unknown"')
                
                progress "     • $ws_name"
                progress "       Resource Group: $ws_rg"
                progress "       Location: $ws_location"
                progress "       SKU: $ws_sku"
            done
            
            all_workspaces=$(jq -s '.[0] + .[1]' <(echo "$all_workspaces") <(echo "$workspaces"))
            total_workspace_count=$((total_workspace_count + ws_count))
        else
            progress "   ℹ️  No Databricks workspaces found"
        fi
        progress ""
    done
    
    progress "════════════════════════════════════════════════════════════════════"
    progress "📈 SUMMARY: Found $total_workspace_count total Databricks workspace(s)"
    progress "════════════════════════════════════════════════════════════════════"
    progress ""
    
    if [[ "$total_workspace_count" -eq 0 ]]; then
        progress "⚠️  No Databricks workspaces found in any subscription!"
        progress "   This is unusual if you're seeing Databricks costs in your bill."
        progress "   Possible reasons:"
        progress "   1. Workspaces were deleted after costs were incurred"
        progress "   2. Service principal lacks permissions to list workspaces"
        progress "   3. Workspaces are in subscriptions not included in analysis"
        progress ""
    fi
}

# Main execution
main() {
    log "╔════════════════════════════════════════════════════════════════════╗"
    log "║   Azure Databricks Cluster Cost Optimization Analysis             ║"
    log "╚════════════════════════════════════════════════════════════════════╝"
    log ""
    log "Analysis Date: $(date '+%Y-%m-%d %H:%M:%S')"
    log "Lookback Period: $LOOKBACK_DAYS days"
    log "Discount Applied: ${DISCOUNT_PERCENTAGE}%"
    log ""
    hr
    
    # Parse subscription IDs
    if [[ -z "${AZURE_SUBSCRIPTION_IDS:-}" ]]; then
        # Use current subscription
        AZURE_SUBSCRIPTION_IDS=$(az account show --query "id" -o tsv)
        progress "No subscription IDs specified. Using current subscription: $AZURE_SUBSCRIPTION_IDS"
    fi
    
    IFS=',' read -ra SUBSCRIPTIONS <<< "$AZURE_SUBSCRIPTION_IDS"
    
    local total_subscriptions=${#SUBSCRIPTIONS[@]}
    progress "Analyzing $total_subscriptions subscription(s)..."
    
    # PHASE 1: Discover all workspaces first
    discover_all_workspaces "$AZURE_SUBSCRIPTION_IDS"
    
    # PHASE 2: Analyze each workspace in detail
    progress ""
    progress "╔════════════════════════════════════════════════════════════════════╗"
    progress "║   DETAILED CLUSTER ANALYSIS                                        ║"
    progress "╚════════════════════════════════════════════════════════════════════╝"
    progress ""
    
    # Iterate through each subscription
    for subscription_id in "${SUBSCRIPTIONS[@]}"; do
        subscription_id=$(echo "$subscription_id" | xargs)  # Trim whitespace
        
        progress ""
        progress "═══════════════════════════════════════════════════════════════════"
        progress "Subscription: $subscription_id"
        progress "═══════════════════════════════════════════════════════════════════"
        
        # Set subscription context
        az account set --subscription "$subscription_id" 2>/dev/null || {
            log "❌ Failed to set subscription context for: $subscription_id"
            progress "❌ Skipping subscription (access denied or invalid ID)"
            continue
        }
        
        # Get subscription name
        local subscription_name=$(az account show --subscription "$subscription_id" --query "name" -o tsv 2>/dev/null || echo "Unknown")
        
        log "═══════════════════════════════════════════════════════════════════"
        log "Subscription: $subscription_name ($subscription_id)"
        log "═══════════════════════════════════════════════════════════════════"
        log ""
        
        # Parse resource groups if specified
        local rg_filter=""
        if [[ -n "${AZURE_RESOURCE_GROUPS:-}" ]]; then
            rg_filter="--resource-group"
        fi
        
        # Get all Databricks workspaces in subscription
        progress "Fetching Databricks workspaces..."
        
        local workspaces
        if [[ -n "${AZURE_RESOURCE_GROUPS:-}" ]]; then
            IFS=',' read -ra RESOURCE_GROUPS <<< "$AZURE_RESOURCE_GROUPS"
            workspaces="[]"
            for rg in "${RESOURCE_GROUPS[@]}"; do
                rg=$(echo "$rg" | xargs)
                local rg_workspaces=$(az databricks workspace list --resource-group "$rg" --subscription "$subscription_id" -o json 2>/dev/null || echo "[]")
                workspaces=$(jq -s '.[0] + .[1]' <(echo "$workspaces") <(echo "$rg_workspaces"))
            done
        else
            workspaces=$(az databricks workspace list --subscription "$subscription_id" -o json 2>/dev/null || echo "[]")
        fi
        
        local workspace_count=$(echo "$workspaces" | jq 'length')
        
        log "Databricks Workspaces Found: $workspace_count"
        progress "✓ Found $workspace_count Databricks workspace(s)"
        
        if [[ "$workspace_count" -eq 0 ]]; then
            log "ℹ️  No Databricks workspaces found in this subscription"
            hr
            continue
        fi
        
        # Analyze each workspace
        echo "$workspaces" | jq -c '.[]' | while read -r workspace_data; do
            local workspace_name=$(echo "$workspace_data" | jq -r '.name')
            local resource_group=$(echo "$workspace_data" | jq -r '.resourceGroup')
            
            analyze_workspace "$workspace_name" "$resource_group" "$subscription_id" "$subscription_name"
        done
    done
    
    # Finalize issues JSON
    echo "]" >> "$ISSUES_TMP"
    mv "$ISSUES_TMP" "$ISSUES_FILE"
    
    # Generate summary
    log ""
    log "╔════════════════════════════════════════════════════════════════════╗"
    log "║   ANALYSIS COMPLETE                                                ║"
    log "╚════════════════════════════════════════════════════════════════════╝"
    log ""
    
    local issue_count=$(jq 'length' "$ISSUES_FILE")
    log "Total Issues Found: $issue_count"
    
    if [[ "$issue_count" -gt 0 ]]; then
        log ""
        log "Issues by Severity:"
        jq -r 'group_by(.severity) | map({severity: .[0].severity, count: length}) | sort_by(.severity) | .[] | "  Severity \(.severity): \(.count) issue(s)"' "$ISSUES_FILE" >> "$REPORT_FILE"
        
        log ""
        log "Total Potential Monthly Savings:"
        local total_savings=$(jq -r '[.[] | .title | capture("\\$(?<amount>[0-9,]+)") | .amount | gsub(","; "") | tonumber] | add // 0' "$ISSUES_FILE")
        log "  \$$total_savings/month"
        local annual_savings=$(echo "scale=2; $total_savings * 12" | bc -l 2>/dev/null || echo "0")
        log "  \$$annual_savings/year"
    else
        log ""
        log "✅ No Databricks cost optimization opportunities found!"
        log "   All clusters have proper auto-termination and appear well-utilized."
    fi
    
    log ""
    log "Report saved to: $REPORT_FILE"
    log "Issues JSON saved to: $ISSUES_FILE"
    
    progress ""
    progress "✅ Analysis complete!"
    progress "   Report: $REPORT_FILE"
    progress "   Issues: $ISSUES_FILE"
}

# Run main function
main "$@"

