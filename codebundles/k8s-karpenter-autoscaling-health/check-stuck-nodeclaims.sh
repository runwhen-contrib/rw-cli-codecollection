#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Flags NodeClaims (or legacy Machines) that appear stuck: long non-ready or deleting.
# Optional: STUCK_NODECLAIM_THRESHOLD_MINUTES (default 30)
# Output: karpenter_stuck_nodeclaim_issues.json
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"

OUTPUT_FILE="${OUTPUT_FILE:-karpenter_stuck_nodeclaim_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
THRESHOLD_MIN="${STUCK_NODECLAIM_THRESHOLD_MINUTES:-30}"

if ! command -v jq &>/dev/null; then
  echo '[{"title":"jq Not Available","details":"Install jq.","severity":3,"next_steps":"Install jq."}]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

now_epoch=$(date +%s)
threshold_sec=$((THRESHOLD_MIN * 60))

nc_raw='{"items":[]}'
if $KUBECTL get crd nodeclaims.karpenter.sh --context "$CONTEXT" &>/dev/null; then
  nc_raw=$($KUBECTL get nodeclaims -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
fi

mach_raw='{"items":[]}'
if $KUBECTL get crd machines.karpenter.sh --context "$CONTEXT" &>/dev/null; then
  mach_raw=$($KUBECTL get machines -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
fi

issues_nc=$(echo "$nc_raw" | jq --argjson now "$now_epoch" --argjson th "$threshold_sec" --arg min "$THRESHOLD_MIN" '
  [.items[]?
   | . as $i
   | ($i.metadata.creationTimestamp | fromdateiso8601) as $c
   | (($now - $c) > $th) as $aged
   | ($i.status.conditions // []) as $conds
   | ([$conds[]? | select(.type=="Ready" and .status=="True")] | length) as $readyok
   | ($i.metadata.deletionTimestamp // null) as $del
   | select(($aged and ($readyok == 0)) or ($del != null))
   | {
       title: (if $del != null then "NodeClaim `\($i.metadata.name)` stuck deleting or slow to terminate"
               else "NodeClaim `\($i.metadata.name)` not Ready after \($min) minutes" end),
       details: ("Name: " + $i.metadata.name + "\nDeletion: " + (($del // "none") | tostring)),
       severity: (if $del != null then 4 else 3 end),
       next_steps: ("kubectl describe nodeclaim " + $i.metadata.name + "; check finalizers and controller logs.")
     }
  ]')

issues_m=$(echo "$mach_raw" | jq --argjson now "$now_epoch" --argjson th "$threshold_sec" '
  [.items[]?
   | . as $i
   | ($i.metadata.creationTimestamp | fromdateiso8601) as $c
   | (($now - $c) > $th) as $aged
   | ($i.status.conditions // []) as $conds
   | ([$conds[]? | select(.type=="Ready" and .status=="True")] | length) as $readyok
   | ($i.metadata.deletionTimestamp // null) as $del
   | select(($aged and ($readyok == 0)) or ($del != null))
   | {
       title: "Machine `\($i.metadata.name)` (legacy) may be stuck",
       details: ("Name: " + $i.metadata.name),
       severity: 3,
       next_steps: "Describe machine and linked provisioner."
     }
  ]')

jq -n --argjson a "$issues_nc" --argjson b "$issues_m" '$a + $b' >"$OUTPUT_FILE"
echo "Stuck check wrote $(jq 'length' "$OUTPUT_FILE") issue(s)"
