#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Cross-checks recent controller log lines with Pending pods (optional triage).
# Output: karpenter_correlation_issues.json
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"

OUTPUT_FILE="${OUTPUT_FILE:-karpenter_correlation_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
NS="${KARPENTER_NAMESPACE:-karpenter}"
LOOKBACK="${RW_LOOKBACK_WINDOW:-30m}"
MAX_TAIL_LINES="${KARPENTER_LOG_MAX_LINES:-300}"
LOG_SNIPPET_FILE="karpenter_corr_logs.txt"

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
      echo "  No correlation found between pending pods and Karpenter controller logs within ${LOOKBACK}."
    else
      jq -r '.[] | "  - [sev=\(.severity)] \(.title)\n      \(.details)\n      Next: \(.next_steps)"' "$OUTPUT_FILE"
    fi
  fi
}
trap print_report EXIT

if ! command -v jq &>/dev/null; then
  echo '[{"title":"jq Not Available","details":"Install jq.","severity":3,"next_steps":"Install jq."}]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

pods_json=$($KUBECTL get pods -A --field-selector=status.phase=Pending -o json --context "$CONTEXT" 2>/dev/null || echo '{"items":[]}')
pending_list=$(echo "$pods_json" | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"')

if ! $KUBECTL get ns "$NS" --context "$CONTEXT" &>/dev/null; then
  echo '[]' | jq . >"$OUTPUT_FILE"
  exit 0
fi

mapfile -t ctrls < <($KUBECTL get pods -n "$NS" --context "$CONTEXT" -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | test("karpenter"; "i")) | .metadata.name' | head -3)
: >"$LOG_SNIPPET_FILE"
for p in "${ctrls[@]}"; do
  [[ -z "$p" ]] && continue
  timeout 60s $KUBECTL logs -n "$NS" "$p" --context "$CONTEXT" --since="$LOOKBACK" --tail="$MAX_TAIL_LINES" --all-containers=true 2>/dev/null >>"$LOG_SNIPPET_FILE" || true
done

issues='[]'
while IFS= read -r pn; do
  [ -z "$pn" ] && continue
  short=$(echo "$pn" | cut -d/ -f2)
  ns=$(echo "$pn" | cut -d/ -f1)
  if [[ ! -s "$LOG_SNIPPET_FILE" ]]; then
    break
  fi
  if grep -Ei "ERROR|WARN|failed|Insufficient|launch|Instance" "$LOG_SNIPPET_FILE" 2>/dev/null | grep -qF "$short"; then
    issues=$(echo "$issues" | jq \
      --arg pn "$pn" \
      --arg short "$short" \
      --arg ns "$ns" \
      '. += [{
        "title": ("Log correlation: pending pod `" + $pn + "` referenced in controller errors"),
        "details": ("Pod name " + $short + " appears in recent Karpenter controller log lines matching error patterns. See the controller log scan task for full excerpts."),
        "severity": 3,
        "next_steps": ("kubectl describe pod -n " + $ns + " " + $short + "; compare with NodeClaim events.")
      }]')
  fi
done <<<"$pending_list"

echo "$issues" | jq . >"$OUTPUT_FILE"
