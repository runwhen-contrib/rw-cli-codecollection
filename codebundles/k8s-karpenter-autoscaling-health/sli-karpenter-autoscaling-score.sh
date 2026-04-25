#!/usr/bin/env bash
set -euo pipefail
# Lightweight SLI dimensions for Karpenter autoscaling (no heavy log tail).
# Emits JSON: {"d_nodepool":0|1,"d_pending":0|1,"d_stuck":0|1}
# Required: CONTEXT; optional: SLI_PENDING_POD_MAX (default 5), STUCK_NODECLAIM_THRESHOLD_MINUTES (default 30)

: "${CONTEXT:?Must set CONTEXT}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
PMAX="${SLI_PENDING_POD_MAX:-5}"
STUCK_MIN="${STUCK_NODECLAIM_THRESHOLD_MINUTES:-30}"
now_epoch=$(date +%s)
th_sec=$((STUCK_MIN * 60))

if ! command -v jq &>/dev/null; then
  echo '{"d_nodepool":0,"d_pending":0,"d_stuck":0,"error":"jq"}'
  exit 0
fi

if ! $KUBECTL --context "$CONTEXT" cluster-info &>/dev/null; then
  echo '{"d_nodepool":0,"d_pending":0,"d_stuck":0,"error":"api"}'
  exit 0
fi

# Dimension 1: any unhealthy condition on NodePool/Provisioner/NodeClaim
bad_np=0
if $KUBECTL get crd nodepools.karpenter.sh --context "$CONTEXT" &>/dev/null; then
  raw=$($KUBECTL get nodepools -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  bad_np=$(echo "$raw" | jq '[.items[]? | (.status.conditions // [])[] | select(.status=="False" or .status=="Unknown")] | length')
elif $KUBECTL get crd provisioners.karpenter.sh --context "$CONTEXT" &>/dev/null; then
  raw=$($KUBECTL get provisioners -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  bad_np=$(echo "$raw" | jq '[.items[]? | (.status.conditions // [])[] | select(.status=="False" or .status=="Unknown")] | length')
fi

bad_nc=0
if $KUBECTL get crd nodeclaims.karpenter.sh --context "$CONTEXT" &>/dev/null; then
  raw=$($KUBECTL get nodeclaims -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  bad_nc=$(echo "$raw" | jq '[.items[]? | (.status.conditions // [])[] | select(.status=="False" or .status=="Unknown")] | length')
fi

d1=1
if [[ "$((bad_np + bad_nc))" -gt 0 ]]; then d1=0; fi

# Dimension 2: pending pods with capacity-like messages (count <= PMAX)
pods_json=$($KUBECTL get pods -A -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
pcount=$(echo "$pods_json" | jq '
  [.items[]?
   | select(.status.phase == "Pending")
   | . as $p
   | (($p.status.conditions // []) | map(.message // "") | join(" ")) as $msg
   | select(($msg | test("insufficient|FailedScheduling|no nodes available|0/[0-9]+ nodes|taint"; "i")))
  ] | length
')
d2=1
if [[ "${pcount:-0}" -gt "$PMAX" ]]; then d2=0; fi

# Dimension 3: stuck nodeclaims (same logic as check-stuck, condensed)
d3=1
if $KUBECTL get crd nodeclaims.karpenter.sh --context "$CONTEXT" &>/dev/null; then
  nc_raw=$($KUBECTL get nodeclaims -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  stuck=$(echo "$nc_raw" | jq --argjson now "$now_epoch" --argjson th "$th_sec" '
    [.items[]?
     | . as $i
     | ($i.metadata.creationTimestamp | fromdateiso8601) as $c
     | (($now - $c) > $th) as $aged
     | ([($i.status.conditions // [])[]? | select(.type=="Ready" and .status=="True")] | length) as $readyok
     | ($i.metadata.deletionTimestamp // null) as $del
     | select(($aged and ($readyok == 0)) or ($del != null))
    ] | length
  ')
  [[ "${stuck:-0}" -gt 0 ]] && d3=0
fi

jq -n --argjson d1 "$d1" --argjson d2 "$d2" --argjson d3 "$d3" \
  '{d_nodepool: $d1, d_pending: $d2, d_stuck: $d3}'
