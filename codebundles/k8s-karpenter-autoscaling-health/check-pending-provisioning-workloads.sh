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

echo "Wrote $(jq 'length' "$OUTPUT_FILE") issue(s) to ${OUTPUT_FILE}"
