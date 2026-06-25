#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, CSI_NAMESPACE
# Checks VAST CSI controller and node pods for readiness and restart issues.
# Writes JSON array to csi_pod_health_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${CSI_NAMESPACE:?Must set CSI_NAMESPACE}"

OUTPUT_FILE="csi_pod_health_issues.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-csi-common.sh
source "${SCRIPT_DIR}/vast-csi-common.sh"

issues_json='[]'

print_report() {
  { set +x; } 2>/dev/null || true
  echo
  echo "=== VAST CSI pods in namespace '${CSI_NAMESPACE}' (context '${CONTEXT}') ==="
  k8s get pods -n "${CSI_NAMESPACE}" -o wide 2>/dev/null || echo "  (unable to list pods)"
  echo
  if [[ -s "$OUTPUT_FILE" ]]; then
    local ic
    ic=$(jq 'length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
    echo "=== Findings (${ic}) ==="
    jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
  fi
}
trap print_report EXIT

if ! k8s get ns "${CSI_NAMESPACE}" -o name &>/dev/null; then
  issues_json=$(append_issue "$issues_json" \
    "VAST CSI namespace \`${CSI_NAMESPACE}\` not found in context \`${CONTEXT}\`" \
    "The configured CSI_NAMESPACE does not exist; driver health cannot be assessed." \
    3 \
    "Verify CSI_NAMESPACE (default: vast-csi) and confirm the VAST CSI Helm release is installed.")
  write_issues "$OUTPUT_FILE" "$issues_json"
  exit 0
fi

check_pods() {
  local role="$1"
  local pods_json="$2"
  local count
  count=$(echo "$pods_json" | jq '.items | length')
  if [[ "$count" -eq 0 ]]; then
    issues_json=$(append_issue "$issues_json" \
      "No VAST CSI ${role} pods found in namespace \`${CSI_NAMESPACE}\`" \
      "Expected ${role} DaemonSet/Deployment pods for the VAST CSI driver were not discovered." \
      2 \
      "Confirm the Helm release installed node/controller components. Check labels and pod selectors in ${CSI_NAMESPACE}.")
    return
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name phase ready restarts crash
    name=$(echo "$line" | jq -r '.name')
    phase=$(echo "$line" | jq -r '.phase')
    ready=$(echo "$line" | jq -r '.ready')
    restarts=$(echo "$line" | jq -r '.restarts')
    crash=$(echo "$line" | jq -r '.crash')

    if [[ "$crash" == "true" ]]; then
      issues_json=$(append_issue "$issues_json" \
        "VAST CSI ${role} pod \`${name}\` is in CrashLoopBackOff" \
        "Pod phase=${phase}, ready=${ready}, restarts=${restarts} in namespace ${CSI_NAMESPACE}." \
        2 \
        "Inspect logs: ${KUBECTL} logs -n ${CSI_NAMESPACE} ${name} --context ${CONTEXT}. Check VMS connectivity and mount permissions.")
    elif [[ "$ready" != "True" ]]; then
      issues_json=$(append_issue "$issues_json" \
        "VAST CSI ${role} pod \`${name}\` is not Ready" \
        "Pod phase=${phase}, restarts=${restarts} in namespace ${CSI_NAMESPACE}." \
        2 \
        "Describe pod: ${KUBECTL} describe pod -n ${CSI_NAMESPACE} ${name} --context ${CONTEXT}.")
    fi

    if [[ "${restarts}" =~ ^[0-9]+$ ]] && [[ "$restarts" -gt 5 ]]; then
      issues_json=$(append_issue "$issues_json" \
        "Elevated restarts on VAST CSI ${role} pod \`${name}\`" \
        "Total container restarts: ${restarts} within namespace ${CSI_NAMESPACE}." \
        2 \
        "Review recent logs and node NFS transport metrics; check for OOM or VMS endpoint instability.")
    fi
  done < <(echo "$pods_json" | jq -c '.items[] | {
    name: .metadata.name,
    phase: (.status.phase // "Unknown"),
    ready: ((.status.conditions // []) | map(select(.type=="Ready")) | .[0].status // "False"),
    restarts: ([.status.containerStatuses[]? | .restartCount // 0] | add // 0),
    crash: ([.status.containerStatuses[]? | .state.waiting.reason? // empty] | map(select(. == "CrashLoopBackOff")) | length > 0)
  }')
}

node_pods=$(find_csi_node_pods)
controller_pods=$(find_csi_controller_pods)

# Fallback: all pods in namespace if selectors miss custom installs
if [[ $(echo "$node_pods" | jq '.items | length') -eq 0 && $(echo "$controller_pods" | jq '.items | length') -eq 0 ]]; then
  all_pods=$(k8s get pods -n "${CSI_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
  node_pods=$(echo "$all_pods" | jq '{items: [.items[] | select(.metadata.name | test("node"; "i"))]}')
  controller_pods=$(echo "$all_pods" | jq '{items: [.items[] | select(.metadata.name | test("controller"; "i"))]}')
fi

check_pods "node" "$node_pods"
check_pods "controller" "$controller_pods"

# Deployment / DaemonSet replica alignment
for kind in deploy statefulset daemonset; do
  resources=$(k8s get "$kind" -n "${CSI_NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
  while IFS= read -r dline; do
    [[ -z "$dline" ]] && continue
    dname=$(echo "$dline" | jq -r '.name')
    want=$(echo "$dline" | jq -r '.desired')
    have=$(echo "$dline" | jq -r '.ready')
    if [[ "$want" =~ ^[0-9]+$ ]] && [[ "$have" =~ ^[0-9]+$ ]] && [[ "$want" -gt 0 ]] && [[ "$have" -lt "$want" ]]; then
      issues_json=$(append_issue "$issues_json" \
        "VAST CSI ${kind} \`${dname}\` is not fully Ready" \
        "readyReplicas=${have}, desired=${want} in namespace ${CSI_NAMESPACE}." \
        2 \
        "${KUBECTL} describe ${kind} -n ${CSI_NAMESPACE} ${dname} --context ${CONTEXT}")
    fi
  done < <(echo "$resources" | jq -c '.items[] | select(.metadata.name | test("vast|csi"; "i")) | {
    name: .metadata.name,
    desired: (.spec.replicas // (.status.desiredNumberScheduled // 0)),
    ready: (.status.readyReplicas // (.status.numberReady // 0))
  }')
done

write_issues "$OUTPUT_FILE" "$issues_json"
