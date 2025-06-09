#!/usr/bin/env bash
# node_pool_health.sh
# BULK DATA OPTIMIZED: Download once, process efficiently in memory
# 
# PERFORMANCE IMPROVEMENTS:
# - Bulk data download with minimal API calls
# - In-memory processing using jq
# - Maintains all issue detection capabilities
# - Parallel data fetching where safe
#
set -uo pipefail

# Prerequisites check
for cmd in gcloud kubectl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "❌ $cmd not found in PATH" >&2
    exit 1
  fi
done

# Environment setup
if [[ -n "${KUBECONFIG:-}" ]]; then
  export KUBECONFIG="$KUBECONFIG"
elif [[ -f "kubeconfig" ]]; then
  export KUBECONFIG="kubeconfig"
else
  TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
  export KUBECONFIG="$TEMP_DIR/kubeconfig_$$"
fi
PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
[[ -z "$PROJECT" ]] && { echo "❌ No GCP project set" >&2; exit 1; }

# Configuration
LOOKBACK_HOURS="${NODE_HEALTH_LOOKBACK_HOURS:-4}"
REPORT_FILE="node_pool_health_report.txt"
ISSUES_FILE="node_pool_health_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/node_pool_health_issues_$$.json"
DATA_TIMEOUT="${DATA_TIMEOUT:-30}"
MAX_OPERATIONS_TO_CHECK="${MAX_OPERATIONS_TO_CHECK:-50}"
MAX_EVENTS_TO_CHECK="${MAX_EVENTS_TO_CHECK:-20}"

# Global data stores
CLUSTERS_DATA=""
ALL_COMPUTE_INSTANCES=""
ALL_INSTANCE_GROUPS=""
ALL_COMPUTE_OPERATIONS=""
CURRENT_CLUSTER_NODES=""
CURRENT_CLUSTER_EVENTS=""

# Initialize outputs
echo -n "[" > "$ISSUES_TMP"
first_issue=true

# Cleanup function
cleanup() {
  jobs -p | xargs -r kill 2>/dev/null || true
  rm -f "$ISSUES_TMP" "$ISSUES_TMP.lock"
  [[ "$KUBECONFIG" =~ kubeconfig_[0-9]+$ ]] && rm -f "$KUBECONFIG" 2>/dev/null || true
}
trap cleanup EXIT

# Logging functions
log() { printf "%s\n" "$*" >> "$REPORT_FILE"; }
hr()  { printf -- '─%.0s' {1..60} >> "$REPORT_FILE"; printf "\n" >> "$REPORT_FILE"; }
progress() { printf "📊 [%s] %s\n" "$(date '+%H:%M:%S')" "$*" >&2; }

# Issue reporting function
add_issue() {
  local TITLE="$1" DETAILS="$2" SEV="$3" NEXT="$4"
  
  log "🔸 $TITLE (severity=$SEV)"
  [[ -n "$DETAILS" ]] && log "$DETAILS"
  log "Next steps: $NEXT"
  hr
  
  $first_issue || echo "," >> "$ISSUES_TMP"
  first_issue=false
  jq -n --arg t "$TITLE" --arg d "$DETAILS" --arg n "$NEXT" --argjson s "$SEV" \
        '{title:$t,details:$d,severity:$s,next_steps:$n}' >> "$ISSUES_TMP"
}

# Timeout wrapper
timeout_cmd() {
  local timeout_duration="$1"
  shift
  timeout "$timeout_duration" "$@" 2>/dev/null || return $?
}

# BULK DATA COLLECTION FUNCTIONS

# Download all project-wide compute data once
download_compute_data() {
  progress "Downloading all compute instances and operations..."
  
  # Get all compute instances in project
  progress "  Downloading compute instances..."
  ALL_COMPUTE_INSTANCES="$(timeout_cmd "$DATA_TIMEOUT" gcloud compute instances list \
    --project="$PROJECT" \
    --format="json(name,zone,status,machineType,metadata.items,labels)" \
    2>/dev/null || echo '[]')"
  
  # Get all managed instance groups in project
  progress "  Downloading instance groups..."
  ALL_INSTANCE_GROUPS="$(timeout_cmd "$DATA_TIMEOUT" gcloud compute instance-groups managed list \
    --project="$PROJECT" \
    --format="json(name,zone,region,instanceTemplate,targetSize,creationTimestamp)" \
    2>/dev/null || echo '[]')"
  
  # Get all recent compute operations
  progress "  Downloading compute operations..."
  ALL_COMPUTE_OPERATIONS="$(timeout_cmd "$DATA_TIMEOUT" gcloud compute operations list \
    --project="$PROJECT" \
    --filter="insertTime>-P${LOOKBACK_HOURS}H" \
    --format="json(name,operationType,status,error.errors[0].message,insertTime,targetLink,zone,region)" \
    --limit="$MAX_OPERATIONS_TO_CHECK" \
    2>/dev/null || echo '[]')"
  
  # Normalize zones from URLs to zone names for easier matching
  ALL_COMPUTE_INSTANCES=$(echo "$ALL_COMPUTE_INSTANCES" | jq '[.[] | .zone = (.zone | split("/") | .[-1])]')
  
  local instance_count=$(echo "$ALL_COMPUTE_INSTANCES" | jq length)
  local ig_count=$(echo "$ALL_INSTANCE_GROUPS" | jq length)
  local ops_count=$(echo "$ALL_COMPUTE_OPERATIONS" | jq length)
  
  progress "✓ Downloaded $instance_count instances, $ig_count instance groups, $ops_count operations"
}

# Download cluster-specific Kubernetes data
download_cluster_k8s_data() {
  local CLUSTER_NAME="$1" CLUSTER_LOC="$2"
  
  # Determine location flag
  local LOC_FLAG
  if [[ "$CLUSTER_LOC" =~ ^[a-z0-9-]+-[a-z0-9-]+-[a-z0-9-]+$ ]]; then
    LOC_FLAG="--region"
  else
    LOC_FLAG="--zone"
  fi
  
  # Get cluster credentials
  if ! timeout_cmd 30 gcloud container clusters get-credentials "$CLUSTER_NAME" \
        "$LOC_FLAG" "$CLUSTER_LOC" --project "$PROJECT" --quiet >/dev/null 2>&1; then
    add_issue "Cannot access cluster \`$CLUSTER_NAME\`" \
              "Unable to fetch cluster credentials for health checking." 3 \
              "Verify GKE cluster access permissions for \`$CLUSTER_NAME\` in project \`$PROJECT\`."
    return 1
  fi
  
  progress "Downloading Kubernetes data for cluster: $CLUSTER_NAME"
  
  # Get all nodes data
  progress "  Downloading K8s nodes..."
  CURRENT_CLUSTER_NODES="$(timeout_cmd 20 kubectl get nodes \
    -o json 2>/dev/null || echo '{"items":[]}')"
  
  # Get all recent events  
  progress "  Downloading K8s events..."
  CURRENT_CLUSTER_EVENTS="$(timeout_cmd 15 kubectl get events \
    --sort-by='.lastTimestamp' \
    -o json 2>/dev/null || echo '{"items":[]}')"
  
  local node_count=$(echo "$CURRENT_CLUSTER_NODES" | jq '.items | length')
  local event_count=$(echo "$CURRENT_CLUSTER_EVENTS" | jq '.items | length')
  progress "✓ Downloaded $node_count nodes, $event_count events for cluster $CLUSTER_NAME"
  
  return 0
}

# ANALYSIS FUNCTIONS - Process downloaded data in memory

# Analyze node pool health using downloaded data
analyze_node_pool_health() {
  local CLUSTER_NAME="$1" CLUSTER_LOC="$2"
  
  progress "Analyzing cluster: $CLUSTER_NAME"
  log "  Cluster: $CLUSTER_NAME ($CLUSTER_LOC)"
  
  # Download cluster K8s data
  if ! download_cluster_k8s_data "$CLUSTER_NAME" "$CLUSTER_LOC"; then
    return
  fi
  
  # Determine location flag for gcloud calls
  local LOC_FLAG
  if [[ "$CLUSTER_LOC" =~ ^[a-z0-9-]+-[a-z0-9-]+-[a-z0-9-]+$ ]]; then
    LOC_FLAG="--region"
  else
    LOC_FLAG="--zone"
  fi
  
  # Get node pools data
  NODE_POOLS_JSON="$(timeout_cmd 20 gcloud container node-pools list \
    --cluster="$CLUSTER_NAME" "$LOC_FLAG"="$CLUSTER_LOC" \
    --project="$PROJECT" \
    --format="json(name,status,config.machineType,autoscaling,currentNodeCount,initialNodeCount,instanceGroupUrls)" \
    2>/dev/null || echo '[]')"
  
  if [[ "$NODE_POOLS_JSON" == "[]" ]]; then
    log "  No node pools found"
    return
  fi
  
  POOL_COUNT=$(echo "$NODE_POOLS_JSON" | jq length)
  log "  Found $POOL_COUNT node pools"
  
  # Process each node pool using in-memory data
  pool_num=0
  while read -r pool_data; do
    ((pool_num++))
    
    POOL_NAME="$(echo "$pool_data" | jq -r '.name')"
    POOL_STATUS="$(echo "$pool_data" | jq -r '.status')"
    MACHINE_TYPE="$(echo "$pool_data" | jq -r '.config.machineType')"
    AUTOSCALING="$(echo "$pool_data" | jq -r '.autoscaling.enabled')"
    MIN_NODES="$(echo "$pool_data" | jq -r '.autoscaling.minNodeCount // .initialNodeCount')"
    MAX_NODES="$(echo "$pool_data" | jq -r '.autoscaling.maxNodeCount // .initialNodeCount')"
    INSTANCE_GROUP_URLS="$(echo "$pool_data" | jq -r '.instanceGroupUrls[]? // empty')"
    
    # Calculate current nodes from actual running instances instead of unreliable currentNodeCount
    local CALCULATED_NODES=0
    if [[ -n "$INSTANCE_GROUP_URLS" ]]; then
      while IFS= read -r ig_url; do
        [[ -z "$ig_url" ]] && continue
        IG_ZONE="$(echo "$ig_url" | sed 's|.*/zones/||' | sed 's|/.*||')"
        IG_HASH="$(echo "$ig_url" | sed 's|.*/instanceGroupManagers/||' | sed 's/.*-\([a-f0-9]\{8\}\)-grp$/\1/')"
        
        local instances_count
        instances_count="$(echo "$ALL_COMPUTE_INSTANCES" | jq --arg zone "$IG_ZONE" --arg ig_hash "$IG_HASH" '
          [.[] | select(.zone == $zone) | select(.name | contains($ig_hash)) | select(.status=="RUNNING")] | length')"
        CALCULATED_NODES=$((CALCULATED_NODES + instances_count))
      done <<< "$INSTANCE_GROUP_URLS"
    fi
    
    # Use calculated nodes if available, otherwise fall back to API data
    if [[ $CALCULATED_NODES -gt 0 ]]; then
      CURRENT_NODES="$CALCULATED_NODES"
    else
      CURRENT_NODES="$(echo "$pool_data" | jq -r '.currentNodeCount // .initialNodeCount')"
    fi
    
    log "    [$pool_num/$POOL_COUNT] Pool: $POOL_NAME ($MACHINE_TYPE)"
    log "      Status: $POOL_STATUS, Nodes: $CURRENT_NODES/$MAX_NODES"
    
    # Check critical pool status
    if [[ "$POOL_STATUS" != "RUNNING" ]]; then
      add_issue "Node pool \`$POOL_NAME\` not running in cluster \`$CLUSTER_NAME\`" \
                "Node pool status: $POOL_STATUS" 2 \
                "Check GCP Console for node pool \`$POOL_NAME\` in cluster \`$CLUSTER_NAME\`."
    fi
    
    # Check for capacity issues
    if [[ "$AUTOSCALING" == "true" && "$CURRENT_NODES" == "$MAX_NODES" && "$MAX_NODES" != "null" && $MAX_NODES -gt 0 ]]; then
      add_issue "Node pool \`$POOL_NAME\` at maximum capacity in cluster \`$CLUSTER_NAME\`" \
                "Current nodes ($CURRENT_NODES) equals maximum nodes ($MAX_NODES)" 2 \
                "Check regional quotas and consider increasing max nodes for pool \`$POOL_NAME\`."
    fi
    
    # Analyze instance groups for this pool using downloaded data
    analyze_pool_instance_groups "$CLUSTER_NAME" "$POOL_NAME" "$INSTANCE_GROUP_URLS"
    
  done < <(echo "$NODE_POOLS_JSON" | jq -c '.[]')
  
  # Cross-validate cluster data
  cross_validate_cluster_data "$CLUSTER_NAME"
  
  # Analyze Kubernetes events
  analyze_kubernetes_events "$CLUSTER_NAME"
  
  # Analyze compute operations for this cluster
  analyze_cluster_compute_operations "$CLUSTER_NAME"
}

# Analyze instance groups using downloaded data
analyze_pool_instance_groups() {
  local CLUSTER_NAME="$1" POOL_NAME="$2" INSTANCE_GROUP_URLS="$3"
  
  if [[ -z "$INSTANCE_GROUP_URLS" ]]; then
    log "      No instance groups found"
    return
  fi
  
  local total_instances=0 running_instances=0 failed_instances=0 ig_count=0
  
  # Process each instance group URL
  while IFS= read -r ig_url; do
    [[ -z "$ig_url" ]] && continue
    ((ig_count++))
    
    IG_NAME="$(echo "$ig_url" | sed 's|.*/instanceGroupManagers/||' | sed 's|.*instanceGroups/||')"
    IG_ZONE="$(echo "$ig_url" | sed 's|.*/zones/||' | sed 's|/.*||')"
    
    # Find instances in this instance group using downloaded data
    # GKE instances follow pattern: gke-{cluster}-{pool}-{hash}-{suffix}
    # Instance group names follow pattern: gke-{cluster}-{pool}-{hash}-grp
    # Extract the hash from instance group name to match instances
    IG_HASH="$(echo "$IG_NAME" | sed 's/.*-\([a-f0-9]\{8\}\)-grp$/\1/')"
    
    INSTANCES_IN_GROUP="$(echo "$ALL_COMPUTE_INSTANCES" | jq --arg zone "$IG_ZONE" --arg ig_hash "$IG_HASH" '
      [.[] | select(.zone == $zone) | select(.name | contains($ig_hash))]')"
    
    if [[ "$INSTANCES_IN_GROUP" != "[]" ]]; then
      local group_total group_running group_failed
      group_total=$(echo "$INSTANCES_IN_GROUP" | jq length)
      group_running=$(echo "$INSTANCES_IN_GROUP" | jq '[.[] | select(.status=="RUNNING")] | length')
      group_failed=$(echo "$INSTANCES_IN_GROUP" | jq '[.[] | select(.status!="RUNNING")] | length')
      
      total_instances=$((total_instances + group_total))
      running_instances=$((running_instances + group_running))
      failed_instances=$((failed_instances + group_failed))
      
      log "        IG: $IG_NAME - $group_running/$group_total running"
      
      # Check for critical issues
      if [[ $group_running -eq 0 && $group_total -gt 0 ]]; then
        add_issue "No running instances in instance group \`$IG_NAME\` for node pool \`$POOL_NAME\`" \
                  "Instance group has $group_total instances but none are running" 1 \
                  "Investigate instance group $IG_NAME in cluster \`$CLUSTER_NAME\`."
      fi
      
      # Check for provisioning failures using downloaded instances data
      local failed_instances_details
      failed_instances_details="$(echo "$INSTANCES_IN_GROUP" | jq -r '.[] | select(.status!="RUNNING") | "\(.name): \(.status)"')"
      if [[ -n "$failed_instances_details" ]]; then
        add_issue "Failed instances detected in node pool \`$POOL_NAME\`" \
                  "Failed instances in $IG_NAME: $failed_instances_details" 2 \
                  "Check instance logs and quotas for cluster \`$CLUSTER_NAME\`."
      fi
    else
      # Try to get instance group data directly if not found in compute instances
      local ig_instances
      ig_instances="$(timeout_cmd 15 gcloud compute instance-groups managed list-instances "$IG_NAME" \
        --zone="$IG_ZONE" --project="$PROJECT" \
        --format="json(instance,instanceStatus)" 2>/dev/null || echo '[]')"
      
      if [[ "$ig_instances" != "[]" ]]; then
        local group_total group_running
        group_total=$(echo "$ig_instances" | jq length)
        group_running=$(echo "$ig_instances" | jq '[.[] | select(.instanceStatus=="RUNNING")] | length')
        
        total_instances=$((total_instances + group_total))
        running_instances=$((running_instances + group_running))
        failed_instances=$((failed_instances + (group_total - group_running)))
        
        log "        IG: $IG_NAME - $group_running/$group_total running (direct query)"
      fi
    fi
    
    # Analyze instance group operations using downloaded data
    analyze_instance_group_operations "$IG_NAME" "$IG_ZONE" "$CLUSTER_NAME" "$POOL_NAME"
    
  done <<< "$INSTANCE_GROUP_URLS"
  
  log "      Summary: $running_instances/$total_instances instances running across $ig_count groups"
  
  # Report significant issues
  if [[ $failed_instances -gt 0 && $failed_instances -gt $((total_instances / 3)) ]]; then
    add_issue "High instance failure rate in node pool \`$POOL_NAME\`" \
              "Failed instances: $failed_instances/$total_instances" 2 \
              "Investigate instance health for node pool \`$POOL_NAME\` in cluster \`$CLUSTER_NAME\`."
  fi
}

# Analyze operations for specific instance group using downloaded data
analyze_instance_group_operations() {
  local IG_NAME="$1" IG_ZONE="$2" CLUSTER_NAME="$3" POOL_NAME="$4"
  
  # Find operations related to this instance group using downloaded data
  local ig_operations
  ig_operations="$(echo "$ALL_COMPUTE_OPERATIONS" | jq --arg ig_name "$IG_NAME" --arg zone "$IG_ZONE" '
    [.[] | select(.zone != null and (.zone | type == "string") and (.zone | contains($zone))) | 
     select(.targetLink != null and (.targetLink | type == "string") and (.targetLink | contains($ig_name) or contains("instanceGroupManagers/" + $ig_name)))]')"
  
  # Check for critical errors
  local critical_errors
  critical_errors="$(echo "$ig_operations" | jq -r '.[] | select(.status=="ERROR" or .status=="FAILED") | 
    select(.error.errors[0].message | test("quota|exhausted|exceeded|ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_NOT_FOUND|disk")) | 
    "\(.operationType): \(.error.errors[0].message)"' | head -3)"
  
  if [[ -n "$critical_errors" ]]; then
    add_issue "Critical operations failures for instance group \`$IG_NAME\`" \
              "Errors: $critical_errors" 1 \
              "Check quotas and resource availability for cluster \`$CLUSTER_NAME\`."
  fi
  
  # Check for recent provisioning failures
  local provisioning_failures
  provisioning_failures="$(echo "$ig_operations" | jq -r '.[] | select(.status=="ERROR") | 
    select(.operationType | test("insert|create")) | 
    "\(.insertTime): \(.error.errors[0].message)"' | head -2)"
  
  if [[ -n "$provisioning_failures" ]]; then
    add_issue "Instance provisioning failures in node pool \`$POOL_NAME\`" \
              "Recent failures: $provisioning_failures" 2 \
              "Investigate provisioning issues for instance group \`$IG_NAME\`."
  fi
}

# Cross-validate using downloaded data
cross_validate_cluster_data() {
  local CLUSTER_NAME="$1"
  
  # Count Kubernetes nodes
  local k8s_node_count
  k8s_node_count="$(echo "$CURRENT_CLUSTER_NODES" | jq '.items | length')"
  
  # Count compute instances for this cluster using downloaded data
  # Fix: Match instances belonging to this specific cluster
  # Try multiple patterns to handle GKE's complex naming (truncation, duplication, etc.)
  local compute_instance_count=0
  
  # Pattern 1: Exact cluster name
  local count1
  count1="$(echo "$ALL_COMPUTE_INSTANCES" | jq --arg cluster "$CLUSTER_NAME" '
    [.[] | select(.name | startswith("gke-" + $cluster + "-"))] | length')"
  
  # Pattern 2: Handle truncated long names (>15 chars get truncated)
  local count2=0
  if [[ ${#CLUSTER_NAME} -gt 15 ]]; then
    local truncated_name
    truncated_name="$(echo "$CLUSTER_NAME" | cut -c1-15)"
    count2="$(echo "$ALL_COMPUTE_INSTANCES" | jq --arg truncated "$truncated_name" '
      [.[] | select(.name | startswith("gke-" + $truncated))] | length')"
  fi
  
  # Pattern 3: Handle duplicated cluster names (like platform-cluster-01 -> platform-cluster-platform-cluster)
  local count3=0
  local cluster_words
  cluster_words="$(echo "$CLUSTER_NAME" | tr '-' ' ')"
  local first_word
  first_word="$(echo "$cluster_words" | awk '{print $1}')"
  if [[ -n "$first_word" && "$first_word" != "$CLUSTER_NAME" ]]; then
    count3="$(echo "$ALL_COMPUTE_INSTANCES" | jq --arg first_word "$first_word" '
      [.[] | select(.name | test("^gke-" + $first_word + "-" + $first_word + "-"))] | length')"
  fi
  
  # Use the pattern that finds the most instances
  if [[ $count1 -gt 0 ]]; then
    compute_instance_count=$count1
    cluster_prefix="gke-$CLUSTER_NAME-"
  elif [[ $count2 -gt 0 ]]; then
    compute_instance_count=$count2
    cluster_prefix="gke-$(echo "$CLUSTER_NAME" | cut -c1-15)"
  elif [[ $count3 -gt 0 ]]; then
    compute_instance_count=$count3
    cluster_prefix="gke-$first_word-$first_word-"
  else
    compute_instance_count=0
    cluster_prefix="gke-$CLUSTER_NAME-"
  fi
  
  log "      Cross-validation: $k8s_node_count K8s nodes, $compute_instance_count compute instances"
  
  # Report significant discrepancies
  local diff=$((k8s_node_count - compute_instance_count))
  if [[ ${diff#-} -gt 1 ]]; then
    add_issue "Node count mismatch in cluster \`$CLUSTER_NAME\`" \
              "Kubernetes nodes: $k8s_node_count, Compute instances: $compute_instance_count" 2 \
              "Investigate node registration for cluster \`$CLUSTER_NAME\`."
  fi
  
  # Check for unregistered instances belonging to this cluster
  local unregistered_instances
  unregistered_instances="$(echo "$ALL_COMPUTE_INSTANCES" | jq --arg prefix "$cluster_prefix" -r '
    .[] | select(.name | startswith($prefix)) | select(.status=="RUNNING") | 
    .name' | while read -r instance_name; do
      if ! echo "$CURRENT_CLUSTER_NODES" | jq -e --arg name "$instance_name" '.items[] | select(.metadata.name != null and (.metadata.name | contains($name)))' >/dev/null 2>&1; then
        echo "$instance_name"
      fi
    done | head -3)"
  
  if [[ -n "$unregistered_instances" ]]; then
    add_issue "Unregistered compute instances in cluster \`$CLUSTER_NAME\`" \
              "Running instances not in Kubernetes: $unregistered_instances" 2 \
              "Investigate node registration issues for cluster \`$CLUSTER_NAME\`."
  fi
}

# Analyze Kubernetes events using downloaded data
analyze_kubernetes_events() {
  local CLUSTER_NAME="$1"
  
  # Filter for critical node events
  local critical_events
  critical_events="$(echo "$CURRENT_CLUSTER_EVENTS" | jq -r --arg hours "$LOOKBACK_HOURS" '
    .items[] | select(.involvedObject.kind=="Node") | 
    select(.type=="Warning") |
    select(.reason | test("FailedMount|DiskPressure|MemoryPressure|NetworkUnavailable|NodeNotReady|NodeNotSchedulable")) |
    select(now - (.lastTimestamp | fromdateiso8601) < ($hours | tonumber * 3600)) |
    "\(.reason): \(.message)"' | head -5)"
  
  if [[ -n "$critical_events" ]]; then
    add_issue "Critical Kubernetes node events in cluster \`$CLUSTER_NAME\`" \
              "Recent events: $critical_events" 2 \
              "Investigate node health for cluster \`$CLUSTER_NAME\`."
  fi
  
  # Check for pod scheduling failures
  local scheduling_failures
  scheduling_failures="$(echo "$CURRENT_CLUSTER_EVENTS" | jq -r --arg hours "$LOOKBACK_HOURS" '
    .items[] | select(.reason=="FailedScheduling") |
    select(now - (.lastTimestamp | fromdateiso8601) < ($hours | tonumber * 3600)) |
    .message' | grep -E "(quota|resource|insufficient)" | head -3)"
  
  if [[ -n "$scheduling_failures" ]]; then
    add_issue "Pod scheduling failures in cluster \`$CLUSTER_NAME\`" \
              "Resource issues: $scheduling_failures" 2 \
              "Check cluster capacity and node pool scaling for \`$CLUSTER_NAME\`."
  fi
}

# Analyze compute operations for cluster using downloaded data
analyze_cluster_compute_operations() {
  local CLUSTER_NAME="$1"
  
  # Find operations related to this cluster
  local cluster_operations
  cluster_operations="$(echo "$ALL_COMPUTE_OPERATIONS" | jq --arg cluster "$CLUSTER_NAME" '
    [.[] | select(.targetLink != null and (.targetLink | contains($cluster) or test("gke-" + $cluster + "-")))]')"
  
  # Check for quota and resource exhaustion
  local resource_errors
  resource_errors="$(echo "$cluster_operations" | jq -r '.[] | select(.status=="ERROR") | 
    select(.error.errors[0].message | test("quota|exhausted|exceeded|ZONE_RESOURCE_POOL_EXHAUSTED")) | 
    "\(.operationType): \(.error.errors[0].message)"' | head -3)"
  
  if [[ -n "$resource_errors" ]]; then
    add_issue "Resource exhaustion detected for cluster \`$CLUSTER_NAME\`" \
              "Failed operations: $resource_errors" 1 \
              "Check quotas and regional capacity for cluster \`$CLUSTER_NAME\`."
  fi
  
  # Check for disk attachment failures
  local disk_errors
  disk_errors="$(echo "$cluster_operations" | jq -r '.[] | select(.status=="ERROR") | 
    select(.error.errors[0].message | test("disk|attach|volume")) | 
    "\(.operationType): \(.error.errors[0].message)"' | head -2)"
  
  if [[ -n "$disk_errors" ]]; then
    add_issue "Disk attachment failures in cluster \`$CLUSTER_NAME\`" \
              "Failed operations: $disk_errors" 2 \
              "Investigate storage issues for cluster \`$CLUSTER_NAME\`."
  fi
}

# MAIN SCRIPT EXECUTION
log "Starting bulk-optimized node pool health check..."
hr

# Initialize report
printf "GKE Node Pool Health Report (BULK OPTIMIZED) — %s\nProject: %s\nLookback: %s hours\n" \
       "$(date -Iseconds)" "$PROJECT" "$LOOKBACK_HOURS" > "$REPORT_FILE"
hr

# Step 1: Download all project-wide compute data once
download_compute_data

# Step 2: Get all clusters
CLUSTERS_JSON="$(timeout_cmd 20 gcloud container clusters list \
  --project="$PROJECT" \
  --format="json(name,location,status)" 2>/dev/null || echo '[]')"

if [[ "$CLUSTERS_JSON" == "[]" ]]; then
  log "No GKE clusters found in project $PROJECT"
  echo "]" >> "$ISSUES_TMP"
  jq . "$ISSUES_TMP" > "$ISSUES_FILE" 2>/dev/null || echo "[]" > "$ISSUES_FILE"
  exit 0
fi

CLUSTER_COUNT=$(echo "$CLUSTERS_JSON" | jq length)
progress "Found $CLUSTER_COUNT clusters in project $PROJECT"
log "Found $CLUSTER_COUNT clusters in project $PROJECT"

# Step 3: Process each cluster using downloaded data
cluster_num=0
while read -r cluster; do
  ((cluster_num++))
  
  CLUSTER_NAME="$(echo "$cluster" | jq -r '.name')"
  CLUSTER_LOC="$(echo "$cluster" | jq -r '.location')"
  CLUSTER_STATUS="$(echo "$cluster" | jq -r '.status')"
  
  progress "[$cluster_num/$CLUSTER_COUNT] Analyzing: $CLUSTER_NAME"
  log "[$cluster_num/$CLUSTER_COUNT] Cluster: $CLUSTER_NAME ($CLUSTER_LOC) - Status: $CLUSTER_STATUS"
  hr
  
  # Check cluster status
  if [[ "$CLUSTER_STATUS" != "RUNNING" ]]; then
    add_issue "Cluster \`$CLUSTER_NAME\` not in RUNNING state" \
              "Cluster status: $CLUSTER_STATUS" 2 \
              "Check cluster status in GCP Console."
  fi
  
  # Analyze cluster using downloaded data
  analyze_node_pool_health "$CLUSTER_NAME" "$CLUSTER_LOC"
  
  hr
  
done < <(echo "$CLUSTERS_JSON" | jq -c '.[]')

# Finalize
log "Bulk-optimized node pool health check completed."
progress "✅ Analysis completed"

# Finalize JSON output
echo "]" >> "$ISSUES_TMP"
if ! jq . "$ISSUES_TMP" > "$ISSUES_FILE" 2>/dev/null; then
  echo "[]" > "$ISSUES_FILE"
  progress "⚠️ JSON output was malformed, created empty issues file"
fi

# Final summary
FINAL_ISSUES_COUNT=0
if [[ -f "$ISSUES_FILE" ]]; then
  FINAL_ISSUES_COUNT=$(jq length "$ISSUES_FILE" 2>/dev/null || echo "0")
fi

echo "✔ Report: $REPORT_FILE"
echo "✔ Issues: $ISSUES_FILE" 
echo "✔ Found $FINAL_ISSUES_COUNT issues with bulk-optimized approach"