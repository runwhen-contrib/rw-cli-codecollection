#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Reads NodeClass / AWSNodeTemplate conditions (provider-specific CRDs).
# Output: karpenter_nodeclass_issues.json
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"

OUTPUT_FILE="${OUTPUT_FILE:-karpenter_nodeclass_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"

if ! command -v jq &>/dev/null; then
  echo '[{"title":"jq Not Available","details":"Install jq.","severity":3,"next_steps":"Install jq."}]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

scan_to_issues() {
  local plural="$1" kind_label="$2"
  if ! $KUBECTL get crd "$plural" --context "$CONTEXT" &>/dev/null; then
    echo '[]'
    return 0
  fi
  local raw
  raw=$($KUBECTL get "$plural" -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
  echo "$raw" | jq --arg kl "$kind_label" '
    [.items[]? as $i
     | ($i.status.conditions // [])[] as $c
     | select($c.status == "False" or $c.status == "Unknown")
     | {
         title: ($kl + " `" + $i.metadata.name + "` condition `" + $c.type + "` is " + $c.status),
         details: ($kl + ": " + $i.metadata.name + "\nCondition: " + $c.type + "\nStatus: " + $c.status + "\nReason: " + ($c.reason // "") + "\nMessage: " + ($c.message // "")),
         severity: 3,
         next_steps: ("Validate subnets, security groups, AMI, and IAM for this " + $kl + "; review controller logs.")
       }
    ]
  '
}

a1=$(scan_to_issues ec2nodeclasses.karpenter.k8s.aws EC2NodeClass)
a2=$(scan_to_issues awsnodetemplates.karpenter.k8s.aws AWSNodeTemplate)
a3=$(scan_to_issues aksnodeclasses.karpenter.azure.com AKSNodeClass)
a4=$(scan_to_issues gcpnodeclasses.karpenter.k8s.gcp GCPNodeClass)

combined=$(jq -n --argjson a "$a1" --argjson b "$a2" --argjson c "$a3" --argjson d "$a4" '$a + $b + $c + $d')

if [[ "$(echo "$combined" | jq 'length')" -eq 0 ]]; then
  any=false
  for c in ec2nodeclasses.karpenter.k8s.aws awsnodetemplates.karpenter.k8s.aws aksnodeclasses.karpenter.azure.com gcpnodeclasses.karpenter.k8s.gcp; do
    if $KUBECTL get crd "$c" --context "$CONTEXT" &>/dev/null; then any=true; break; fi
  done
  if [[ "$any" == "false" ]]; then
    combined='[{"title":"No Supported NodeClass CRDs Detected","details":"No EC2NodeClass/AWSNodeTemplate/Azure/GCP NodeClass CRDs found.","severity":2,"next_steps":"Confirm Karpenter version and cloud provider CRDs are installed."}]'
  fi
fi

echo "$combined" | jq . >"$OUTPUT_FILE"
echo "NodeClass scan wrote $(jq 'length' "$OUTPUT_FILE") issue(s)"
