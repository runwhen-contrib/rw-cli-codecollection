#!/bin/bash
# gke_cluster_health_nodepool_crashloop_list.sh
#
# This script checks each GKE cluster for:
#   - node readiness
#   - CPU/memory usage (aggregated by node pool label)
#   - CrashLoopBackOff pods.
#
# For CrashLoop pods, the severity logic is:
#   - If ANY pod's namespace is in a "critical" list => severity=1
#   - Else => severity=4
#
# Additionally:
#   - If we cannot fetch credentials for a cluster, we create an issue (severity=4 or as you like).
#   - The "Suggested Next Steps" for CrashLoop pods now explicitly mentions "Check Namespace Health" for each namespace found.

set -euo pipefail

if ! command -v gcloud &>/dev/null; then
  echo "Error: gcloud not found." >&2
  exit 1
fi
if ! command -v kubectl &>/dev/null; then
  echo "Error: kubectl not found." >&2
  exit 1
fi

# Set KUBECONFIG so that gcloud can configure it with the appropriate credentials
export KUBECONFIG="kubeconfig"

# Comma-separated list of critical namespaces. If any CrashLoop pod is in one of these => severity=1, else 4.
CRITICAL_NAMESPACES="${CRITICAL_NAMESPACES:-kube-system}"

# Convert to an array for easy checking
IFS=',' read -r -a CRITICAL_NS_ARRAY <<< "$CRITICAL_NAMESPACES"

PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ -z "$PROJECT" ]; then
  echo "Error: No project set. Use PROJECT env or 'gcloud config set project <PROJECT_ID>'." >&2
  exit 1
fi

REPORT_FILE="cluster_health_report.txt"
ISSUES_FILE="cluster_health_issues.json"

{
  echo "GKE Cluster Health Report"
  echo "Project: $PROJECT"
  echo "-------------------------------------"
} > "$REPORT_FILE"

TEMP_ISSUES="cluster_health_issues_temp.json"
echo "[" > "$TEMP_ISSUES"
first_issue=true

#########################
# 1) List GKE clusters
#########################
echo "Fetching GKE clusters in project '$PROJECT'..."
CLUSTERS_JSON="$(gcloud container clusters list --project="$PROJECT" --format=json || true)"
if [ -z "$CLUSTERS_JSON" ] || [ "$CLUSTERS_JSON" = "[]" ]; then
  echo "No GKE clusters found in project '$PROJECT'." | tee -a "$REPORT_FILE"
  echo "]" >> "$TEMP_ISSUES"
  mv "$TEMP_ISSUES" "$ISSUES_FILE"
  exit 0
fi

NUM_CLUSTERS="$(echo "$CLUSTERS_JSON" | jq length)"
for i in $(seq 0 $((NUM_CLUSTERS - 1))); do
  CLUSTER_NAME="$(echo "$CLUSTERS_JSON" | jq -r ".[$i].name")"
  CLUSTER_LOC="$(echo "$CLUSTERS_JSON" | jq -r ".[$i].location")"
  if [ -z "$CLUSTER_NAME" ] || [ "$CLUSTER_NAME" = "null" ]; then
    continue
  fi

  # Attempt to get credentials. If we fail, create an issue and skip.
  if ! gcloud container clusters get-credentials "$CLUSTER_NAME" \
       --zone "$CLUSTER_LOC" \
       --project "$PROJECT" >/dev/null 2>&1; then

    echo "Error: failed to get credentials for $CLUSTER_NAME. Skipping." | tee -a "$REPORT_FILE"

    # Create a separate issue in the JSON and the report.
    T="Insufficient Permissions / Error Getting Credentials for GKE Cluster \`$CLUSTER_NAME\`"
    D="We do not have permission to get cluster credentials (or cluster does not exist)."
    S=4  # e.g. 'major' or 'informational'; pick your own
    R="Grant Container/Cluster credentials for GKE Cluster \`$CLUSTER_NAME\`."

    {
      echo "Issue: $T"
      echo "Details: $D"
      echo "Severity: $S"
      echo "Suggested Next Steps: $R"
      echo "-------------------------------------"
    } >> "$REPORT_FILE"

    if [ "$first_issue" = true ]; then
      first_issue=false
    else
      echo "," >> "$TEMP_ISSUES"
    fi

    jq -n \
      --arg title "$T" \
      --arg details "$D" \
      --arg suggested "$R" \
      --argjson severity "$S" \
      '{title: $title, details: $details, severity: $severity, suggested: $suggested}' \
      >> "$TEMP_ISSUES"

    # Now skip to next cluster
    continue
  fi

  #########################
  # 2) Check node readiness
  #########################
  echo "Checking node statuses..." | tee -a "$REPORT_FILE"
  NODE_STATUSES="$(kubectl get nodes --no-headers 2>/dev/null || true)"
  if [ -z "$NODE_STATUSES" ]; then
    echo "No nodes found or error for cluster $CLUSTER_NAME." | tee -a "$REPORT_FILE"
    continue
  fi
  echo "$NODE_STATUSES" >> "$REPORT_FILE"

  NOT_READY="$(echo "$NODE_STATUSES" | grep -v " Ready " || true)"
  if [ -n "$NOT_READY" ]; then
    T="Node(s) Not Ready in GKE Cluster \`$CLUSTER_NAME\`"
    D="The following nodes are not Ready:\n$NOT_READY"
    S=2
    R="Use 'kubectl describe node <NAME>' or check underlying VM health."

    {
      echo "Issue: $T"
      echo "Details: $D"
      echo "Severity: $S"
      echo "Suggested Next Steps: $R"
      echo "-------------------------------------"
    } >> "$REPORT_FILE"

    if [ "$first_issue" = true ]; then
      first_issue=false
    else
      echo "," >> "$TEMP_ISSUES"
    fi
    jq -n \
      --arg title "$T" \
      --arg details "$D" \
      --arg suggested "$R" \
      --argjson severity "$S" \
      '{title: $title, details: $details, severity: $severity, suggested: $suggested}' \
      >> "$TEMP_ISSUES"
  fi

  #########################################################
  # 3) Node CPU/Memory usage, aggregated by nodepool label
  #########################################################
  echo "Checking node CPU/Memory usage with 'kubectl top nodes'..." | tee -a "$REPORT_FILE"
  TOP_NODES="$(kubectl top nodes --no-headers 2>/dev/null || true)"
  if [ -z "$TOP_NODES" ]; then
    echo "No 'kubectl top' data. Possibly metrics server missing." | tee -a "$REPORT_FILE"
  else
    echo "$TOP_NODES" >> "$REPORT_FILE"

    # Build a map from nodeName => nodePool
    NODEPOOL_MAP="$(kubectl get nodes -o json | jq -r '.items[] | "\(.metadata.name) \(.metadata.labels["cloud.google.com/gke-nodepool"] // "unknown")"')"
    declare -A NODEPOOL_OF
    while read -r line; do
      nodeN="$(echo "$line" | awk '{print $1}')"
      poolN="$(echo "$line" | awk '{print $2}')"
      NODEPOOL_OF["$nodeN"]="$poolN"
    done <<< "$NODEPOOL_MAP"

    # We'll store CPU & mem issues in a map keyed by nodepool.
    declare -A CPU_ISSUES
    declare -A MEM_ISSUES

    while IFS= read -r line; do
      # e.g. "gke-mycluster-mypool-abc 4000m 100% 6132Mi 60%"
      nodeName="$(echo "$line" | awk '{print $1}')"
      cpuPctRaw="$(echo "$line" | awk '{print $3}' | tr -d '%')"
      memPctRaw="$(echo "$line" | awk '{print $5}' | tr -d '%')"
      poolName="${NODEPOOL_OF[$nodeName]:-unknown}"

      CPU_PCT=0
      MEM_PCT=0
      [[ "$cpuPctRaw" =~ ^[0-9]+$ ]] && CPU_PCT="$cpuPctRaw"
      [[ "$memPctRaw" =~ ^[0-9]+$ ]] && MEM_PCT="$memPctRaw"

      # thresholds: >=90 => severity=1, >=75 => severity=2
      if [ "$CPU_PCT" -ge 75 ]; then
        CPU_ISSUES["$poolName"]+="$nodeName=${CPU_PCT}%;"
      fi
      if [ "$MEM_PCT" -ge 75 ]; then
        MEM_ISSUES["$poolName"]+="$nodeName=${MEM_PCT}%;"
      fi
    done <<< "$TOP_NODES"

    # produce aggregated issues for CPU
    for pool in "${!CPU_ISSUES[@]}"; do
      entries="${CPU_ISSUES[$pool]}"
      severity=2
      IFS=';' read -ra arr <<< "$entries"
      for e in "${arr[@]}"; do
        pct="$(echo "$e" | grep -oE '[0-9]+%' | tr -d '%')"
        if [ -n "$pct" ] && [ "$pct" -ge 90 ]; then
          severity=1
          break
        fi
      done
      T="High CPU usage in GKE cluster \`$CLUSTER_NAME\`, nodepool \`$pool\`"
      D="Nodes exceeding 75% CPU:\n$(echo "$entries" | sed 's/;/\n/g')"
      R="Consider scaling or investigating CPU usage on node pool \`$pool\`."

      {
        echo "Issue: $T"
        echo "Details: $D"
        echo "Severity: $severity"
        echo "Suggested Next Steps: $R"
        echo "-------------------------------------"
      } >> "$REPORT_FILE"

      if [ "$first_issue" = true ]; then
        first_issue=false
      else
        echo "," >> "$TEMP_ISSUES"
      fi
      jq -n --arg title "$T" --arg details "$D" --arg suggested "$R" --argjson severity "$severity" \
        '{title: $title, details: $details, severity: $severity, suggested: $suggested}' >> "$TEMP_ISSUES"
    done

    # produce aggregated issues for memory
    for pool in "${!MEM_ISSUES[@]}"; do
      entries="${MEM_ISSUES[$pool]}"
      severity=2
      IFS=';' read -ra arr <<< "$entries"
      for e in "${arr[@]}"; do
        pct="$(echo "$e" | grep -oE '[0-9]+%' | tr -d '%')"
        if [ -n "$pct" ] && [ "$pct" -ge 90 ]; then
          severity=1
          break
        fi
      done
      T="High memory usage in cluster \`$CLUSTER_NAME\`, nodepool \`$pool\`"
      D="Nodes exceeding 75% memory:\n$(echo "$entries" | sed 's/;/\n/g')"
      R="Consider investigating memory usage or resizing node pool \`$pool\`."

      {
        echo "Issue: $T"
        echo "Details: $D"
        echo "Severity: $severity"
        echo "Suggested Next Steps: $R"
        echo "-------------------------------------"
      } >> "$REPORT_FILE"

      if [ "$first_issue" = true ]; then
        first_issue=false
      else
        echo "," >> "$TEMP_ISSUES"
      fi
      jq -n --arg title "$T" --arg details "$D" --arg suggested "$R" --argjson severity "$severity" \
        '{title: $title, details: $details, severity: $severity, suggested: $suggested}' >> "$TEMP_ISSUES"
    done
  fi

  #############################################
  # 4) CrashLoopBackOff with "critical" list
  #############################################
  echo "Checking for pods in CrashLoopBackOff (using critical namespace list)..." | tee -a "$REPORT_FILE"
  CRASHLOOP="$(kubectl get pods -A --no-headers 2>/dev/null | awk '$4 ~ /CrashLoopBackOff/')"
  if [ -n "$CRASHLOOP" ]; then
    # We gather the unique namespaces so we can mention them specifically
    declare -A NS_OF_CRASHLOOP=()
    ANY_CRITICAL_NS=false
    countCrash="$(echo "$CRASHLOOP" | wc -l)"

    while IFS= read -r line; do
      ns="$(echo "$line" | awk '{print $1}')"
      NS_OF_CRASHLOOP["$ns"]=1  # just mark it
      # check if ns in array
      for cns in "${CRITICAL_NS_ARRAY[@]}"; do
        if [ "$ns" = "$cns" ]; then
          ANY_CRITICAL_NS=true
          break
        fi
      done
      if $ANY_CRITICAL_NS; then
        # we can break once we know there's a critical ns
        break
      fi
    done <<< "$CRASHLOOP"

    # We'll build a short list of all the namespaces that have CrashLoop
    all_crash_ns="$(printf "%s\n" "${!NS_OF_CRASHLOOP[@]}" | sort | paste -sd ', ' -)"

    if $ANY_CRITICAL_NS; then
      s=1
    else
      s=4
    fi

    T="Pods in CrashLoopBackOff in GKE cluster \`$CLUSTER_NAME\`"
    D="Found $countCrash crashing pods:\n$CRASHLOOP"

    # Build a next-steps message that includes "Check Namespace Health" for each namespace
    R="Check the health of these namespaces: $all_crash_ns.
Use 'kubectl logs -n <namespace> <pod>' and check the controlling Deployment/StatefulSet.
If the namespace is in '$CRITICAL_NAMESPACES', treat as urgent."

    {
      echo "Issue: $T"
      echo "Details: $D"
      echo "Severity: $s"
      echo "Suggested Next Steps: $R"
      echo "-------------------------------------"
    } >> "$REPORT_FILE"

    if [ "$first_issue" = true ]; then
      first_issue=false
    else
      echo "," >> "$TEMP_ISSUES"
    fi

    jq -n \
      --arg title "$T" \
      --arg details "$D" \
      --arg suggested "$R" \
      --argjson severity "$s" \
      '{title: $title, details: $details, severity: $severity, suggested: $suggested}' \
      >> "$TEMP_ISSUES"
  fi

done

echo "]" >> "$TEMP_ISSUES"
mv "$TEMP_ISSUES" "$ISSUES_FILE"

echo "Report generated: $REPORT_FILE"
echo "Issues file generated: $ISSUES_FILE"
