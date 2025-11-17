#!/usr/bin/env bash
# gke_cluster_health_nodepool_crashloop_list.sh
# Rev‑2.1 — 2025‑04‑18
set -euo pipefail

# ───────── prerequisites ─────────
for bin in gcloud kubectl jq; do
  command -v "$bin" &>/dev/null || { echo "❌  $bin not found" >&2; exit 1; }
done

export KUBECONFIG="${KUBECONFIG:-kubeconfig}"
PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
[[ -z "$PROJECT" ]] && { echo "❌  No GCP project set" >&2; exit 1; }

IFS=',' read -r -a CRITICAL_NS_ARRAY <<< "${CRITICAL_NAMESPACES:-kube-system}"

REPORT_FILE="cluster_health_report.txt"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
ISSUES_TMP="$TEMP_DIR/cluster_health_issues_$$.json"
echo -n "[" > "$ISSUES_TMP"
first_issue=true

log() { printf "%s\n" "$*" >> "$REPORT_FILE"; }
hr()  { printf -- '─%.0s' {1..80} >> "$REPORT_FILE"; printf "\n" >> "$REPORT_FILE"; }

printf "GKE Cluster Health Report — %s\nProject: %s\n" \
       "$(date -Iseconds)" "$PROJECT" > "$REPORT_FILE"
hr

process_cluster() {
  local CLUSTER_NAME="$1" CLUSTER_LOC="$2"

  if ! gcloud container clusters get-credentials "$CLUSTER_NAME" \
        --zone "$CLUSTER_LOC" --project "$PROJECT" --quiet >/dev/null 2>&1; then
    add_issue "No credentials for cluster \`$CLUSTER_NAME\`" \
              "Unable to fetch kube‑credentials." 4 \
              "Grant Container Cluster Viewer/Admin for \`$CLUSTER_NAME\`."
    log "Cluster: $CLUSTER_NAME ($CLUSTER_LOC) — credentials ❌"; hr; return
  fi

  log "Cluster: $CLUSTER_NAME ($CLUSTER_LOC)"; hr

  # ── 1) Node readiness ────────────────────────────────────────────────
  local NODE_STATUSES NOT_READY
  NODE_STATUSES="$(kubectl get nodes --no-headers 2>/dev/null || true)"
  if [[ -z "$NODE_STATUSES" ]]; then
    log "No nodes or unable to list nodes"; hr
  else
    printf "%-60s %s\n" "NODE" "STATUS" >> "$REPORT_FILE"
    printf "%-60s %s\n" "----" "------" >> "$REPORT_FILE"
    echo "$NODE_STATUSES" | awk '{printf "%-60s %s\n",$1,$2}' >> "$REPORT_FILE"; hr

    NOT_READY="$(echo "$NODE_STATUSES" | awk '$2!="Ready"')"

    local not_ready_nodes="$(awk '{print $1}' <<<"$NOT_READY" | paste -sd ', ' -)"

    if [[ -n "$NOT_READY" ]]; then
      local severity=2
      local title="Node(s) Not Ready in \`$CLUSTER_NAME\`"
      local details="The following nodes are not Ready:\n$NOT_READY"
      local next_steps="Check Kubernetes Cluser Node Health\nCheck Kubernetes Cluster Autoscaler Health\n"

      local summary="Nodes $not_ready_nodes in \`$CLUSTER_NAME\` are in a Not Ready state, \
indicating capacity or pod functionality issues within the GKE cluster. The expected \
condition is that all nodes are available. \
This may be a result of preemptible nodes or cluster resizing activities. Ensure that cluster capacity \
reqiorements are being met and nodes are healthy."

      add_issue "$title" "$details" "$severity" "$next_steps" "$summary"
    fi
  fi

  # ── 2) CPU / memory by node‑pool ─────────────────────────────────────
  local TOP_NODES
  TOP_NODES="$(kubectl top nodes --no-headers 2>/dev/null || true)"
  if [[ -n "$TOP_NODES" ]]; then
    printf "%-60s %6s %6s\n" "NODE" "CPU%" "MEM%" >> "$REPORT_FILE"
    printf "%-60s %6s %6s\n" "----" "----" "----" >> "$REPORT_FILE"

    declare -A NODEPOOL_OF CPU_ISSUES MEM_ISSUES NODEPOOL_TOTAL_NODES NODEPOOL_ALL_NODES
    while read -r n p; do 
      NODEPOOL_OF["$n"]="$p"
      NODEPOOL_TOTAL_NODES["$p"]=$((${NODEPOOL_TOTAL_NODES["$p"]:-0} + 1))
      NODEPOOL_ALL_NODES["$p"]+="$n;"
    done < <(
      kubectl get nodes -o json |
      jq -r '.items[]|[.metadata.name, (.metadata.labels["cloud.google.com/gke-nodepool"]//"unknown")]|@tsv'
    )

    # The output of `kubectl top nodes` → five columns.
    while read -r node _ cpu_pct _ mem_pct; do
      printf "%-60s %6s %6s\n" "$node" "$cpu_pct" "$mem_pct" >> "$REPORT_FILE"

      cpu_pct_num="${cpu_pct%\%}"; mem_pct_num="${mem_pct%\%}"
      pool="${NODEPOOL_OF[$node]}"

      [[ $cpu_pct_num =~ ^[0-9]+$ ]] && (( cpu_pct_num >= 75 )) && \
        CPU_ISSUES["$pool"]+="$node=${cpu_pct_num}%;"
      [[ $mem_pct_num =~ ^[0-9]+$ ]] && (( mem_pct_num >= 75 )) && \
        MEM_ISSUES["$pool"]+="$node=${mem_pct_num}%;"
    done <<< "$TOP_NODES"
    hr

    report_pool_usage "CPU"   CPU_ISSUES NODEPOOL_TOTAL_NODES NODEPOOL_ALL_NODES
    report_pool_usage "memory" MEM_ISSUES NODEPOOL_TOTAL_NODES NODEPOOL_ALL_NODES
    
    # Check for underutilized clusters with cost savings opportunities
    check_underutilization "$TOP_NODES" NODEPOOL_OF NODEPOOL_TOTAL_NODES
  else
    log "kubectl‑top not available (metrics‑server?)"; hr
  fi

  # ── 3) CrashLoopBackOff pods ────────────────────────────────────────
  local CRASHLOOP
  CRASHLOOP="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4=="CrashLoopBackOff"')"
  if [[ -n "$CRASHLOOP" ]]; then
    declare -A NSMAP; local ANY_CRITICAL=false
    while read -r ns _; do
      NSMAP["$ns"]=1
      for c in "${CRITICAL_NS_ARRAY[@]}"; do [[ $ns == "$c" ]] && ANY_CRITICAL=true; done
    done <<< "$CRASHLOOP"

    local SUGG_NS; SUGG_NS="$(printf "%s\n" "${!NSMAP[@]}" | sort | paste -sd ',')"

    # get "pod/namespace" combinations
    CRASHLOOP_COMBINED="$(echo "$CRASHLOOP" | awk '{print $2 "/" $1}' | paste -sd ',')"

    local title="CrashLoopBackOff pods in \`$CLUSTER_NAME\`"
    local details="Crashing pods:\n$CRASHLOOP"
    local severity=$([[ $ANY_CRITICAL == true ]] && echo 1 || echo 4)
    
    local next_steps="Inspect pods and namespace health: \`$SUGG_NS\`"
    next_steps+=$'\nVerify container image integrity and pull status in `'"$CLUSTER_NAME"$'`'
    next_steps+=$'\nExamine recent kubelet and scheduler logs in `'"$CLUSTER_NAME"$'`'
    next_steps+=$'\nAssess network policies and DNS configuration in `'"$CLUSTER_NAME"$'`'

    local summary="In \`$CLUSTER_NAME\`, several pods are in a CrashLoopBackOff state, \
including $CRASHLOOP_COMBINED. This indicates potential capacity or pod functionality \
issues within the GKE cluster. Recommended actions include checking the health of these \
namespaces, verifying container image integrity and pull status, reviewing kubelet and \
scheduler logs, and assessing network policies and DNS configuration."

    add_issue "$title" "$details" "$severity" "$next_steps" "$summary"
  fi
}

add_issue() {
  local TITLE="$1" DETAILS="$2" SEV="$3" NEXT="$4" SUMMARY="${5:-}"
  log "🔸  $TITLE (severity=$SEV)"; [[ -n "$DETAILS" ]] && log "$DETAILS"
  log "Next‑steps: $NEXT"; hr
  $first_issue || echo "," >> "$ISSUES_TMP"; first_issue=false
  jq -n --arg t "$TITLE" --arg d "$DETAILS" --arg n "$NEXT" --argjson s "$SEV" --arg summary "$SUMMARY" \
        '{title:$t,details:$d,severity:$s,suggested:$n,summary:$summary}' >> "$ISSUES_TMP"
}

# GCP Machine Type Pricing (MSRP per hour in USD - 2024 estimates)
get_machine_type_cost() {
  local machine_type="$1"
  case "$machine_type" in
    # Standard machine types
    n2-standard-2)  echo "0.097" ;;
    n2-standard-4)  echo "0.194" ;;
    n2-standard-8)  echo "0.388" ;;
    n2-standard-16) echo "0.776" ;;
    n2-standard-32) echo "1.552" ;;
    n2-standard-48) echo "2.328" ;;
    n2-standard-64) echo "3.104" ;;
    n2-standard-80) echo "3.880" ;;
    
    # High-CPU machine types
    n2-highcpu-2)  echo "0.071" ;;
    n2-highcpu-4)  echo "0.142" ;;
    n2-highcpu-8)  echo "0.284" ;;
    n2-highcpu-16) echo "0.568" ;;
    n2-highcpu-32) echo "1.136" ;;
    n2-highcpu-48) echo "1.704" ;;
    n2-highcpu-64) echo "2.272" ;;
    n2-highcpu-80) echo "2.840" ;;
    
    # High-memory machine types
    n2-highmem-2)  echo "0.130" ;;
    n2-highmem-4)  echo "0.260" ;;
    n2-highmem-8)  echo "0.520" ;;
    n2-highmem-16) echo "1.040" ;;
    n2-highmem-32) echo "2.080" ;;
    n2-highmem-48) echo "3.120" ;;
    n2-highmem-64) echo "4.160" ;;
    n2-highmem-80) echo "5.200" ;;
    
    # E2 machine types (more cost-effective)
    e2-standard-2)  echo "0.067" ;;
    e2-standard-4)  echo "0.134" ;;
    e2-standard-8)  echo "0.268" ;;
    e2-standard-16) echo "0.536" ;;
    e2-standard-32) echo "1.072" ;;
    
    # Default fallback for unknown types
    *) echo "0.100" ;;
  esac
}

check_underutilization() {
  local TOP_NODES="$1"
  local -n NODEPOOL_OF_REF="$2"
  local -n NODEPOOL_TOTAL_NODES_REF="$3"
  
  # Track utilization by node pool
  declare -A POOL_CPU_TOTAL POOL_MEM_TOTAL POOL_CPU_COUNT POOL_MEM_COUNT POOL_MACHINE_TYPES
  
  # Parse node utilization data
  while read -r node _ cpu_pct _ mem_pct; do
    cpu_pct_num="${cpu_pct%\%}"; mem_pct_num="${mem_pct%\%}"
    pool="${NODEPOOL_OF_REF[$node]}"
    
    if [[ $cpu_pct_num =~ ^[0-9]+$ ]] && [[ $mem_pct_num =~ ^[0-9]+$ ]]; then
      POOL_CPU_TOTAL["$pool"]=$((${POOL_CPU_TOTAL["$pool"]:-0} + cpu_pct_num))
      POOL_MEM_TOTAL["$pool"]=$((${POOL_MEM_TOTAL["$pool"]:-0} + mem_pct_num))
      POOL_CPU_COUNT["$pool"]=$((${POOL_CPU_COUNT["$pool"]:-0} + 1))
      POOL_MEM_COUNT["$pool"]=$((${POOL_MEM_COUNT["$pool"]:-0} + 1))
    fi
  done <<< "$TOP_NODES"
  
  # Get machine types for each pool
  local POOLS_JSON
  POOLS_JSON="$(kubectl get nodes -o json | jq -r '.items[] | [(.metadata.labels["cloud.google.com/gke-nodepool"] // "unknown"), (.metadata.labels["node.kubernetes.io/instance-type"] // "unknown")] | @tsv' | sort -u)"
  
  while read -r pool machine_type; do
    [[ -n "$pool" && "$pool" != "unknown" ]] && POOL_MACHINE_TYPES["$pool"]="$machine_type"
  done <<< "$POOLS_JSON"
  
  # Analyze each pool for underutilization
  for pool in "${!POOL_CPU_TOTAL[@]}"; do
    local cpu_count=${POOL_CPU_COUNT["$pool"]:-0}
    local mem_count=${POOL_MEM_COUNT["$pool"]:-0}
    local total_nodes=${NODEPOOL_TOTAL_NODES_REF["$pool"]:-0}
    
    if [[ $cpu_count -gt 0 && $mem_count -gt 0 && $total_nodes -gt 1 ]]; then
      local avg_cpu=$(( POOL_CPU_TOTAL["$pool"] / cpu_count ))
      local avg_mem=$(( POOL_MEM_TOTAL["$pool"] / mem_count ))
      local machine_type="${POOL_MACHINE_TYPES["$pool"]:-unknown}"
      
      # Check for underutilization (both CPU and memory below 25%)
      if [[ $avg_cpu -lt 25 && $avg_mem -lt 25 ]]; then
        # Calculate potential cost savings
        local hourly_cost_per_node
        hourly_cost_per_node="$(get_machine_type_cost "$machine_type")"
        
        # Estimate how many nodes could be removed (conservative approach)
        local max_utilization=$((avg_cpu > avg_mem ? avg_cpu : avg_mem))
        local utilization_factor
        if [[ $max_utilization -lt 10 ]]; then
          utilization_factor=60  # Could potentially remove 60% of nodes
        elif [[ $max_utilization -lt 15 ]]; then
          utilization_factor=40  # Could potentially remove 40% of nodes
        else
          utilization_factor=25  # Could potentially remove 25% of nodes
        fi
        
        local removable_nodes=$(( (total_nodes * utilization_factor) / 100 ))
        [[ $removable_nodes -lt 1 ]] && removable_nodes=1
        
        # Calculate monthly savings (24 hours * 30 days)
        local monthly_savings_per_node
        monthly_savings_per_node="$(echo "scale=2; $hourly_cost_per_node * 24 * 30" | bc -l)"
        local total_monthly_savings
        total_monthly_savings="$(echo "scale=2; $monthly_savings_per_node * $removable_nodes" | bc -l)"
        
        # Determine severity based on potential savings
        local severity=4
        if (( $(echo "$total_monthly_savings > 500" | bc -l) )); then
          severity=3  # High savings potential
        elif (( $(echo "$total_monthly_savings > 200" | bc -l) )); then
          severity=4  # Medium savings potential
        fi
        
        local title="Possible Cost Savings: Node pool \`$pool\` underutilized in cluster \`$CLUSTER_NAME\`"
        local details="\
UNDERUTILIZATION COST ANALYSIS:
- Node Pool: $pool
- Cluster: $CLUSTER_NAME
- Machine Type: $machine_type
- Current Nodes: $total_nodes
- Average CPU Utilization: $avg_cpu%
- Average Memory Utilization: $avg_mem%
- Hourly Cost per Node: \$$hourly_cost_per_node (MSRP estimate)

COST SAVINGS OPPORTUNITY:
- Potentially Removable Nodes: $removable_nodes (${utilization_factor}% reduction)
- Monthly Cost per Node: \$$monthly_savings_per_node
- **Estimated Monthly Savings: \$$total_monthly_savings**
- Annual Savings Potential: \$$(echo "scale=2; $total_monthly_savings * 12" | bc -l)

UNDERUTILIZATION ANALYSIS:
This node pool is underutilized with both CPU and memory usage well optimal levels. The low utilization suggests over-provisioned infrastructure relative to actual workload demands.

BUSINESS IMPACT:
- Unnecessary infrastructure costs of approximately \$$total_monthly_savings per month
- Inefficient resource allocation
- Opportunity for budget reallocation to higher-value initiatives

RECOMMENDATIONS:
1. Review workload resource requests and limits
2. Consider reducing node pool size or switching to smaller machine types
3. Implement cluster autoscaling and right-sizing policies
4. Set up utilization monitoring and alerts"
        local next_steps="\
Review workload resource usage
Consider scaling down node pool for cluster $CLUSTER_NAME
Analyze pod resource requests
Validate cluster autoscaling configuration for cluster $CLUSTER_NAME

        printf -v summary_content "Node pool \`%s\` in cluster \`%s\` is underutilized, with average CPU at %s%% and memory at %s%%, leading to estimated unnecessary costs of \$$%s per month. It is recommended to review workload resource usage, consider scaling down the node pool, analyze pod resource requests, and enable cluster autoscaling to improve resource allocation and reduce costs." \
          "$pool" "$CLUSTER_NAME" "$avg_cpu" "$avg_mem" "$total_monthly_savings"
        local summary="$summary_content"

        add_issue "$title" "$details" "$severity" "$next_steps" "$summary"
      fi
    fi
  done
}

report_pool_usage() {
  local KIND="$1" ARR_NAME="$2" TOTAL_ARR_NAME="$3" ALL_NODES_ARR_NAME="$4"
  declare -n ARR="$ARR_NAME" TOTAL_ARR="$TOTAL_ARR_NAME" ALL_NODES_ARR="$ALL_NODES_ARR_NAME"
  
  for pool in "${!ARR[@]}"; do
    local entries="${ARR[$pool]}" max=0 min=100 sum=0 count=0
    local affected_nodes=() all_pool_nodes
    
    # Parse affected nodes and calculate statistics
    for kv in ${entries//;/ }; do
      [[ -z "$kv" ]] && continue
      local node="${kv%%=*}" pct_str="${kv##*=}"
      pct="${pct_str%\%}"
      [[ $pct =~ ^[0-9]+$ ]] || continue
      
      affected_nodes+=("$node:$pct%")
      (( pct > max )) && max=$pct
      (( pct < min )) && min=$pct
      sum=$((sum + pct))
      count=$((count + 1))
    done
    
    # Get total nodes in pool and calculate percentages
    local total_nodes=${TOTAL_ARR[$pool]:-0}
    local affected_count=${#affected_nodes[@]}
    local affected_percentage=0
    [[ $total_nodes -gt 0 ]] && affected_percentage=$(( (affected_count * 100) / total_nodes ))
    
    # Calculate average usage of affected nodes
    local avg_usage=0
    [[ $count -gt 0 ]] && avg_usage=$((sum / count))
    
    # Determine severity based on both peak usage and percentage of pool affected
    local sev=4
    if (( max >= 90 )) || (( affected_percentage >= 75 )); then
      sev=1  # Critical: Very high usage or most of pool affected
    elif (( max >= 85 )) || (( affected_percentage >= 50 )); then
      sev=2  # High: High usage or significant portion affected
    elif (( max >= 80 )) || (( affected_percentage >= 25 )); then
      sev=3  # Medium: Moderate usage or some nodes affected
    fi
    
    # Build comprehensive issue details
    local severity_desc
    case $sev in
      1) severity_desc="CRITICAL" ;;
      2) severity_desc="HIGH" ;;
      3) severity_desc="MEDIUM" ;;
      4) severity_desc="LOW" ;;
    esac
    
    # Get all nodes in pool for context
    IFS=';' read -ra all_pool_nodes <<< "${ALL_NODES_ARR[$pool]}"
    local healthy_nodes=()
    for node in "${all_pool_nodes[@]}"; do
      [[ -n "$node" ]] || continue
      local is_affected=false
      for affected in "${affected_nodes[@]}"; do
        [[ "${affected%%:*}" == "$node" ]] && is_affected=true && break
      done
      [[ $is_affected == false ]] && healthy_nodes+=("$node")
    done
    local title="High $KIND usage in \`$CLUSTER_NAME\`, node‑pool \`$pool\` ($severity_desc)"
    
    local details="NODE POOL $KIND USAGE ANALYSIS:
- Node Pool: $pool
- Cluster: $CLUSTER_NAME
- Resource: $KIND
- Severity: $severity_desc ($sev)

IMPACT ASSESSMENT:
- Total Nodes in Pool: $total_nodes
- Affected Nodes (≥75%): $affected_count ($affected_percentage% of pool)
- Healthy Nodes (<75%): ${#healthy_nodes[@]} ($(( 100 - affected_percentage ))% of pool)

USAGE STATISTICS:
- Peak Usage: $max%
- Average Usage (affected nodes): $avg_usage%
- Usage Range: $min% - $max%

AFFECTED NODES:
$(printf '%s\n' "${affected_nodes[@]}")

HEALTHY NODES:
$(printf '%s\n' "${healthy_nodes[@]}")

ANALYSIS:
$(if (( affected_percentage >= 75 )); then
  echo "🔴 CRITICAL: Most of the node pool is experiencing high $KIND usage. This indicates systemic resource pressure."
elif (( affected_percentage >= 50 )); then
  echo "🟠 HIGH: Significant portion of the node pool has high $KIND usage. Resource constraints are affecting pool capacity."
elif (( affected_percentage >= 25 )); then
  echo "🟡 MEDIUM: Some nodes in the pool have high $KIND usage. Monitor for spreading resource pressure."
else
  echo "🟢 LOW: Only a few nodes affected. May be due to workload distribution or specific node issues."
fi)

BUSINESS IMPACT:
$(if (( sev <= 2 )); then
  echo "High risk of pod scheduling failures, performance degradation, and potential service disruptions."
elif (( sev == 3 )); then
  echo "Moderate risk of resource constraints affecting new workloads and performance."
else
  echo "Low immediate risk but should be monitored for trend analysis."
fi)"

    local next_steps="Scale or optimise workloads on node‑pool \`$pool\`"
    if (( affected_percentage >= 50 )); then
      next_steps="URGENT: Scale up node‑pool \`$pool\` or optimize high-usage workloads\nAnalyze pod resource requests and limits\nConsider node pool autoscaling configuration\nReview workload distribution across nodes"
    elif (( affected_percentage >= 25 )); then
      next_steps="Scale node‑pool \`$pool\` or redistribute workloads\nAnalyze resource usage patterns\nOptimize pod resource allocation\nMonitor for continued growth"
    else
      next_steps="Monitor node‑pool \`$pool\` resource trends\nInvestigate specific high-usage nodes\nOptimize workloads on affected nodes\nConsider workload rebalancing"
    fi

    printf -v summary_content "High %s usage was detected in \`%s\` on node-pool \`%s\`, with some nodes reaching %s CPU utilization. This exceeds the expected threshold for available capacity and may impact pod functionality. Actions needed include scaling or optimizing workloads, investigating pod resource consumption, reviewing recent changes, and analyzing historical %s usage trends in \`%s\`." \
      "$KIND" "$CLUSTER_NAME" "$pool" "${affected_percentage}%" "$KIND" "$CLUSTER_NAME"
    local summary="$summary_content"

    add_issue "$title" "$details" "$sev" "$next_steps" "$summary"
  done
}

# ───────── main ─────────
CLUSTERS_JSON="$(gcloud container clusters list --project="$PROJECT" --format=json)"
[[ "$CLUSTERS_JSON" == "[]" ]] && { echo "No clusters found"; echo "]" >> "$ISSUES_TMP"; jq . "$ISSUES_TMP" > cluster_health_issues.json; exit 0; }

while read -r row; do
  process_cluster "$(jq -r .name <<<"$row")" "$(jq -r .location <<<"$row")"
done < <(jq -c '.[]' <<< "$CLUSTERS_JSON")

echo "]" >> "$ISSUES_TMP"
jq . "$ISSUES_TMP" > cluster_health_issues.json
rm -f "$ISSUES_TMP"

echo "✔  Report:  $REPORT_FILE"
echo "✔  Issues:  cluster_health_issues.json"
