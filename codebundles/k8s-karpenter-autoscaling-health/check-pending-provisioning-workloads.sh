#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Finds Pending pods with messages suggesting capacity/provisioning problems.
# Required: CONTEXT
# Output: karpenter_pending_workload_issues.json
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"

OUTPUT_FILE="${OUTPUT_FILE:-karpenter_pending_workload_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"

# See comment in check-karpenter-nodepool-nodeclaim-status.sh for rationale.
print_report() {
  { set +x; } 2>/dev/null
  echo
  echo "=== Pending pods cluster-wide (context '${CONTEXT}') ==="
  "${KUBECTL}" get pods -A --field-selector=status.phase=Pending --context "${CONTEXT}" 2>/dev/null \
    || echo "  (unable to list pods)"
  echo
  if [[ -s "$OUTPUT_FILE" ]]; then
    local ic
    ic=$(jq 'length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
    echo "=== Findings (${ic}) ==="
    if [[ "$ic" -eq 0 ]]; then
      echo "  No pending pods showing scheduling or capacity pressure."
    else
      jq -r '.[] | "  - [sev=\(.severity)] \(.title)\n      \(.details)\n      Next: \(.next_steps)"' "$OUTPUT_FILE"
    fi
  fi
}
trap print_report EXIT

if ! command -v jq &>/dev/null; then
  echo '[{"title":"jq Not Available","details":"Install jq.","severity":3,"next_steps":"Install jq on the runner."}]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

pods_json=$($KUBECTL get pods -A -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')

echo "$pods_json" | jq '
  [.items[]
   | select(.status.phase == "Pending")
   | . as $p
   | (($p.status.conditions // []) | map(.message // "") | join(" ")) as $msg
   | select(($msg | test("insufficient|FailedScheduling|no nodes available|topology spread|Preemption|0/[0-9]+ nodes|taint|not enough|could not schedule|couldn.t schedule|did not match|nominated"; "i")))
   | {
       title: ("Pending pod `" + $p.metadata.namespace + "/" + $p.metadata.name + "` suggests scheduling or capacity pressure"),
       details: ("Namespace: " + $p.metadata.namespace + "\nPod: " + $p.metadata.name + "\nMessages: " + $msg),
       severity: 3,
       next_steps: ("kubectl describe pod -n " + $p.metadata.namespace + " " + $p.metadata.name + "; review events and Karpenter logs.")
     }
  ]
' >"$OUTPUT_FILE"
