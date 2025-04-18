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
ISSUES_TMP="$(mktemp)"
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

    declare -A NODEPOOL_OF CPU_ISSUES MEM_ISSUES
    while read -r n p; do NODEPOOL_OF["$n"]="$p"; done < <(
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

    report_pool_usage "CPU"   CPU_ISSUES
    report_pool_usage "memory" MEM_ISSUES
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
  local KIND="$1" ARR_NAME="$2"; declare -n ARR="$ARR_NAME"
  for pool in "${!ARR[@]}"; do
    local entries="${ARR[$pool]}" max=0
    for kv in ${entries//;/ }; do
      pct="${kv##*=}"; pct="${pct%\%}"
      [[ $pct =~ ^[0-9]+$ ]] && (( pct > max )) && max=$pct
    done
    local sev=2; (( max >= 90 )) && sev=1
    add_issue "High $KIND usage in \`$CLUSTER_NAME\`, node‑pool \`$pool\`" \
              "Nodes ≥75% $KIND:\n${entries//;/\n}" \
              "$sev" \
              "Scale or optimise workloads on node‑pool \`$pool\`."
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
