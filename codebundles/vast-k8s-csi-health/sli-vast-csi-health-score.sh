#!/usr/bin/env bash
set -euo pipefail
# Lightweight SLI dimensions for VAST CSI health (stdout JSON object).
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${CSI_NAMESPACE:?Must set CSI_NAMESPACE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-csi-common.sh
source "${SCRIPT_DIR}/vast-csi-common.sh"

XPRT_PENDING_THRESHOLD="${XPRT_PENDING_THRESHOLD:-100}"
RPC_ERROR_RATE_THRESHOLD="${RPC_ERROR_RATE_THRESHOLD:-5}"

csi_pod_score=1
pvc_bound_score=1
mount_score=1
xprt_score=1

# CSI controller/node readiness
if k8s get ns "${CSI_NAMESPACE}" -o name &>/dev/null; then
  node_pods=$(find_csi_node_pods)
  controller_pods=$(find_csi_controller_pods)
  pods=$(jq -n --argjson n "$node_pods" --argjson c "$controller_pods" '{items: ($n.items + $c.items)}')
  not_ready=$(echo "$pods" | jq '[.items[] | select(
    ((.status.conditions // []) | map(select(.type=="Ready")) | .[0].status // "False") != "True"
  )] | length')
  crash=$(echo "$pods" | jq '[.items[] | select(
    ([.status.containerStatuses[]? | .state.waiting.reason? // empty] | index("CrashLoopBackOff"))
  )] | length')
  [[ "${not_ready:-0}" -gt 0 || "${crash:-0}" -gt 0 ]] && csi_pod_score=0
else
  csi_pod_score=0
fi

# VAST PVC binding in workload namespace
pvcs=$(list_vast_pvcs_json "${NAMESPACE}")
if [[ $(echo "$pvcs" | jq '.items | length') -eq 0 ]]; then
  all=$(k8s get pvc -n "${NAMESPACE}" -o json 2>/dev/null || echo '{"items":[]}')
  unbound=0
  total=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    is_vast_pvc_json "$line" || continue
    total=$((total + 1))
    phase=$(echo "$line" | jq -r '.status.phase')
    [[ "$phase" != "Bound" ]] && unbound=$((unbound + 1))
  done < <(echo "$all" | jq -c '.items[]?')
  [[ "$total" -gt 0 && "$unbound" -gt 0 ]] && pvc_bound_score=0
else
  unbound=$(echo "$pvcs" | jq '[.items[] | select(.status.phase != "Bound")] | length')
  [[ "${unbound:-0}" -gt 0 ]] && pvc_bound_score=0
fi

# Mount health: pods using vast PVCs not ready
mount_problems=0
while IFS= read -r pvc; do
  [[ -z "$pvc" ]] && continue
  pods=$(k8s get pods -n "${NAMESPACE}" -o json 2>/dev/null | jq -r --arg p "$pvc" '
    .items[] | select(.spec.volumes[]?.persistentVolumeClaim.claimName == $p) | .metadata.name')
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    ready=$(k8s get pod "$pod" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)
    phase=$(k8s get pod "$pod" -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo Unknown)
    if [[ "$ready" != "True" || "$phase" == "Pending" ]]; then
      mount_problems=$((mount_problems + 1))
    fi
  done <<< "$pods"
done < <(echo "$pvcs" | jq -r '.items[].metadata.name // empty')

[[ "$mount_problems" -gt 0 ]] && mount_score=0

# NFS xprt congestion (best effort)
node_pod=$(find_csi_node_pods | jq -r '.items[0].metadata.name // empty')
if [[ -n "$node_pod" ]]; then
  body=$(curl_pod_metrics "$node_pod" "${CSI_NAMESPACE}" "${NODE_METRICS_PORT:-9090}")
  if echo "$body" | grep -q 'csi_node_nfs_xprt_congested_state'; then
    if echo "$body" | awk '/^csi_node_nfs_xprt_congested_state\{/{if ($NF >= 1) found=1} END{exit !found}'; then
      xprt_score=0
    fi
  fi
  if echo "$body" | awk -v th "$XPRT_PENDING_THRESHOLD" '/^csi_node_nfs_xprt_pending_requests\{/{if ($NF > th) found=1} END{exit !found}'; then
    xprt_score=0
  fi
  if echo "$body" | awk '/^csi_node_nfs_xprt_unhealthy\{/{if ($NF >= 1) found=1} END{exit !found}'; then
    xprt_score=0
  fi
fi

jq -n \
  --argjson c "$csi_pod_score" \
  --argjson p "$pvc_bound_score" \
  --argjson m "$mount_score" \
  --argjson x "$xprt_score" \
  '{csi_pods: $c, pvc_bound: $p, mounts: $m, nfs_xprt: $x}'
