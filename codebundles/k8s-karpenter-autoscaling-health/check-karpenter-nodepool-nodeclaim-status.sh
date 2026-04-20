#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Summarizes Karpenter NodePool/Provisioner and NodeClaim/Machine health.
# Required: CONTEXT, KUBERNETES_DISTRIBUTION_BINARY (optional, default kubectl)
# Output: karpenter_nodepool_nodeclaim_issues.json (JSON array of issues)
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"

OUTPUT_FILE="${OUTPUT_FILE:-karpenter_nodepool_nodeclaim_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
issues_json='[]'

add_issue() {
  local title="$1" details="$2" severity="$3" next_steps="$4"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": $severity,
      "next_steps": $next_steps
    }]')
}

if ! command -v jq &>/dev/null; then
  add_issue "jq Not Available for Karpenter Status Check" "Install jq on the runner to parse Kubernetes JSON output." 3 "Install jq or use an image that includes it."
  echo "$issues_json" >"$OUTPUT_FILE"
  echo "ERROR: jq required"
  exit 0
fi

if ! $KUBECTL --context "$CONTEXT" cluster-info &>/dev/null; then
  add_issue "Cannot Reach Kubernetes API for Context \`${CONTEXT}\`" "kubectl cluster-info failed; verify kubeconfig and context name." 4 "Confirm CONTEXT matches an entry in kubeconfig and credentials are valid."
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

has_crd() {
  $KUBECTL get crd "$1" --context "$CONTEXT" &>/dev/null
}

# --- NodePool / Provisioner conditions ---
if has_crd nodepools.karpenter.sh; then
  np_json=$($KUBECTL get nodepools -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=$(echo "$line" | jq -r '.name')
    ctype=$(echo "$line" | jq -r '.type')
    status=$(echo "$line" | jq -r '.status')
    reason=$(echo "$line" | jq -r '.reason // ""')
    msg=$(echo "$line" | jq -r '.message // ""')
    if [[ "$status" == "False" || "$status" == "Unknown" ]]; then
      add_issue "NodePool \`${name}\` condition \`${ctype}\` is ${status}" \
        "NodePool: ${name}\nCondition: ${ctype}\nStatus: ${status}\nReason: ${reason}\nMessage: ${msg}" \
        3 \
        "Review NodePool spec, limits, and reference templates; check Karpenter controller logs in KARPENTER_NAMESPACE."
    fi
  done < <(echo "$np_json" | jq -c '.items[]? | . as $i | ($i.status.conditions // [])[] | {name: $i.metadata.name} + .')
elif has_crd provisioners.karpenter.sh; then
  prov_json=$($KUBECTL get provisioners -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=$(echo "$line" | jq -r '.name')
    ctype=$(echo "$line" | jq -r '.type')
    status=$(echo "$line" | jq -r '.status')
    reason=$(echo "$line" | jq -r '.reason // ""')
    msg=$(echo "$line" | jq -r '.message // ""')
    if [[ "$status" == "False" || "$status" == "Unknown" ]]; then
      add_issue "Provisioner \`${name}\` condition \`${ctype}\` is ${status}" \
        "Provisioner: ${name}\nCondition: ${ctype}\nStatus: ${status}\nReason: ${reason}\nMessage: ${msg}" \
        3 \
        "Review legacy Provisioner configuration and migrate to NodePools when possible."
    fi
  done < <(echo "$prov_json" | jq -c '.items[]? | . as $i | ($i.status.conditions // [])[] | {name: $i.metadata.name} + .')
else
  add_issue "Karpenter NodePool/Provisioner CRDs Not Found" \
    "Neither nodepools.karpenter.sh nor provisioners.karpenter.sh CRDs were detected in this cluster." \
    2 \
    "Install Karpenter or verify you are connected to the correct cluster context."
fi

# --- NodeClaim / Machine conditions ---
if has_crd nodeclaims.karpenter.sh; then
  nc_json=$($KUBECTL get nodeclaims -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=$(echo "$line" | jq -r '.name')
    ctype=$(echo "$line" | jq -r '.type')
    status=$(echo "$line" | jq -r '.status')
    reason=$(echo "$line" | jq -r '.reason // ""')
    msg=$(echo "$line" | jq -r '.message // ""')
    if [[ "$status" == "False" || "$status" == "Unknown" ]]; then
      sev=3
      [[ "$ctype" == "Initialized" || "$ctype" == "Registered" ]] && sev=4 || true
      add_issue "NodeClaim \`${name}\` condition \`${ctype}\` is ${status}" \
        "NodeClaim: ${name}\nCondition: ${ctype}\nStatus: ${status}\nReason: ${reason}\nMessage: ${msg}" \
        "${sev}" \
        "Describe the NodeClaim and related NodeClass; inspect instance launch errors in controller logs."
    fi
  done < <(echo "$nc_json" | jq -c '.items[]? | . as $i | ($i.status.conditions // [])[] | {name: $i.metadata.name} + .')
elif has_crd machines.karpenter.sh; then
  m_json=$($KUBECTL get machines -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name=$(echo "$line" | jq -r '.name')
    ctype=$(echo "$line" | jq -r '.type')
    status=$(echo "$line" | jq -r '.status')
    reason=$(echo "$line" | jq -r '.reason // ""')
    msg=$(echo "$line" | jq -r '.message // ""')
    if [[ "$status" == "False" || "$status" == "Unknown" ]]; then
      add_issue "Machine \`${name}\` (legacy) condition \`${ctype}\` is ${status}" \
        "Machine: ${name}\nCondition: ${ctype}\nStatus: ${status}\nReason: ${reason}\nMessage: ${msg}" \
        3 \
        "Upgrade Karpenter and migrate to NodeClaims; inspect linked Provisioner and AWSNodeTemplate."
    fi
  done < <(echo "$m_json" | jq -c '.items[]? | . as $i | ($i.status.conditions // [])[] | {name: $i.metadata.name} + .')
fi

# --- Nodes: NotReady or cordoned ---
nodes_json=$($KUBECTL get nodes -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
while IFS= read -r nrow; do
  [ -z "$nrow" ] && continue
  nname=$(echo "$nrow" | jq -r '.name')
  ready=$(echo "$nrow" | jq -r '.ready')
  cordoned=$(echo "$nrow" | jq -r '.cordoned')
  if [[ "$ready" != "True" ]]; then
    add_issue "Node \`${nname}\` is not Ready" \
      "Node ${nname} Ready condition status: ${ready}" \
      3 \
      "kubectl describe node ${nname}; check kubelet, CNI, and instance health. Review linked NodeClaim."
  fi
  if [[ "$cordoned" == "true" ]]; then
    add_issue "Node \`${nname}\` is cordoned (unschedulable)" \
      "Node ${nname} has spec.unschedulable=true." \
      2 \
      "Confirm intentional cordon; if not, uncordon or investigate drain/consolidation."
  fi
done < <(echo "$nodes_json" | jq -c '.items[] | {
  name: .metadata.name,
  ready: ([.status.conditions[]? | select(.type=="Ready")][0].status // "Unknown"),
  cordoned: (.spec.unschedulable // false)
}')

echo "$issues_json" >"$OUTPUT_FILE"
echo "Wrote $(echo "$issues_json" | jq 'length') issue(s) to ${OUTPUT_FILE}"
