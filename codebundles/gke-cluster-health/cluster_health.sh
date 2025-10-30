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
    [[ -n "$NOT_READY" ]] && \
      add_issue "Node(s) Not Ready in \`$CLUSTER_NAME\`" \
                "The following nodes are not Ready:\n$NOT_READY" 2 \
                "kubectl describe node <name> && kubectl get events --field-selector involvedObject.name=<name>"
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
    add_issue "CrashLoopBackOff pods in \`$CLUSTER_NAME\`" \
              "Crashing pods:\n$CRASHLOOP" \
              "$([[ $ANY_CRITICAL == true ]] && echo 1 || echo 4)" \
              "Inspect pods and namespace health: \`$SUGG_NS\`"
  fi
}

add_issue() {
  local TITLE="$1" DETAILS="$2" SEV="$3" NEXT="$4"
  log "🔸  $TITLE (severity=$SEV)"; [[ -n "$DETAILS" ]] && log "$DETAILS"
  log "Next‑steps: $NEXT"; hr
  $first_issue || echo "," >> "$ISSUES_TMP"; first_issue=false
  jq -n --arg t "$TITLE" --arg d "$DETAILS" --arg n "$NEXT" --argjson s "$SEV" \
        '{title:$t,details:$d,severity:$s,suggested:$n}' >> "$ISSUES_TMP"
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
      next_steps="URGENT: Scale up node‑pool \`$pool\` or optimize high-usage workloads\\nAnalyze pod resource requests and limits\\nConsider node pool autoscaling configuration\\nReview workload distribution across nodes"
    elif (( affected_percentage >= 25 )); then
      next_steps="Scale node‑pool \`$pool\` or redistribute workloads\\nAnalyze resource usage patterns\\nOptimize pod resource allocation\\nMonitor for continued growth"
    else
      next_steps="Monitor node‑pool \`$pool\` resource trends\\nInvestigate specific high-usage nodes\\nOptimize workloads on affected nodes\\nConsider workload rebalancing"
    fi
    
    add_issue "$title" "$details" "$sev" "$next_steps"
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
