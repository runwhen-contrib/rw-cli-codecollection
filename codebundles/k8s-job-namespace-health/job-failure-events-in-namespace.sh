#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Collects Warning (or non-Normal) events in lookback window for Job-owned pods.
# Uses RW_LOOKBACK_WINDOW (e.g. 24h, 30m). Writes JOB_FAILURE_EVENTS_ISSUES_FILE.
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

BIN="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="${JOB_FAILURE_EVENTS_ISSUES_FILE:-job_failure_events_issues.json}"
LOOKBACK="${RW_LOOKBACK_WINDOW:-24h}"
issues_json='[]'

parse_lookback_seconds() {
  local s="${1:-24h}"
  s="${s// /}"
  if [[ "$s" =~ ^([0-9]+)h$ ]]; then echo $((${BASH_REMATCH[1]} * 3600)); return; fi
  if [[ "$s" =~ ^([0-9]+)m$ ]]; then echo $((${BASH_REMATCH[1]} * 60)); return; fi
  if [[ "$s" =~ ^([0-9]+)d$ ]]; then echo $((${BASH_REMATCH[1]} * 86400)); return; fi
  if [[ "$s" =~ ^([0-9]+)s$ ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ "$s" =~ ^[0-9]+$ ]]; then echo $((${s#} * 3600)); return; fi
  echo 86400
}

AGE_SEC=$(parse_lookback_seconds "$LOOKBACK")

if ! events_json=$("$BIN" get events -n "$NAMESPACE" --context "$CONTEXT" -o json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Cannot List Events in Namespace \`$NAMESPACE\`" \
    --arg details "$err_msg" \
    --argjson severity 4 \
    --arg next_steps "Verify RBAC for events in namespace" \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "job-failure-events: cannot list Events (context \`${CONTEXT}\`, namespace \`${NAMESPACE}\`, lookback \`${LOOKBACK}\`)."
  echo "kubectl error: ${err_msg}"
  echo "Wrote ${OUTPUT_FILE} ($(echo "$issues_json" | jq 'length') issue(s))."
  exit 0
fi
rm -f err.log

if ! pods_json=$("$BIN" get pods -n "$NAMESPACE" --context "$CONTEXT" -o json 2>err.log); then
  err_msg=$(cat err.log || true)
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Cannot List Pods in Namespace \`$NAMESPACE\`" \
    --arg details "$err_msg" \
    --argjson severity 4 \
    --arg next_steps "Verify RBAC for pods in namespace" \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "job-failure-events: cannot list Pods (context \`${CONTEXT}\`, namespace \`${NAMESPACE}\`)."
  echo "kubectl error: ${err_msg}"
  echo "Wrote ${OUTPUT_FILE} ($(echo "$issues_json" | jq 'length') issue(s))."
  exit 0
fi
rm -f err.log

jobpods=$(echo "$pods_json" | jq '[.items[] | select([.metadata.ownerReferences[]? | select(.kind=="Job")] | length > 0) | .metadata.name]')

issues_payload=$(echo "$events_json" | jq --argjson age "$AGE_SEC" --argjson jp "$jobpods" '
  [.items[] | select(.involvedObject.kind == "Pod" and (.involvedObject.name as $n | $jp | index($n) != null))]
  | map(
      . as $e |
      (($e.lastTimestamp // $e.eventTime // $e.firstTimestamp) // "") as $ts |
      select(($ts | length) > 0 and ((now - ($ts | fromdateiso8601)) <= $age))
    )
  | map(select(.type == "Warning" or .type != "Normal"))
  | group_by(.involvedObject.name)
  | map({
      pod: .[0].involvedObject.name,
      count: length,
      reasons: [.[].reason] | unique,
      sample_msg: (.[0].message // "")
    })
')

event_item_count=$(echo "$events_json" | jq '.items | length')
jobpod_count=$(echo "$jobpods" | jq 'length')
warn_groups=$(echo "$issues_payload" | jq 'length')

if [[ "$warn_groups" -eq 0 ]]; then
  echo "$issues_json" > "$OUTPUT_FILE"
  echo "Context: CONTEXT=${CONTEXT} NAMESPACE=${NAMESPACE} lookback=${LOOKBACK} (${AGE_SEC}s)"
  echo "Events in namespace (list): ${event_item_count} | Job-owned pods (names): ${jobpod_count}"
  echo "Result: No Warning or non-Normal events tied to those pods within the lookback window."
  echo "Wrote ${OUTPUT_FILE} (0 issues)."
  exit 0
fi

while IFS= read -r grp; do
  [[ "$grp" == "null" ]] && continue
  podn=$(echo "$grp" | jq -r '.pod')
  c=$(echo "$grp" | jq '.count')
  reasons=$(echo "$grp" | jq -r '.reasons | join(", ")')
  sample=$(echo "$grp" | jq -r '.sample_msg')
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Recent events for Job pod \`$podn\` in \`$NAMESPACE\`" \
    --arg details "$c event(s). Reasons: $reasons. Sample: $sample" \
    --argjson severity 3 \
    --arg next_steps "kubectl describe pod $podn -n $NAMESPACE; kubectl get events -n $NAMESPACE --field-selector involvedObject.name=$podn" \
    '. += [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]')
done < <(echo "$issues_payload" | jq -c '.[]')

issue_count=$(echo "$issues_json" | jq 'length')
echo "$issues_json" > "$OUTPUT_FILE"
echo "Context: CONTEXT=${CONTEXT} NAMESPACE=${NAMESPACE} lookback=${LOOKBACK} (${AGE_SEC}s)"
echo "Events in namespace (list): ${event_item_count} | Job-owned pods: ${jobpod_count} | Pods with warning/non-Normal groups: ${warn_groups}"
echo "Result: ${issue_count} issue(s) from recent Job pod events."
echo "Wrote ${OUTPUT_FILE} (${issue_count} issue(s))."
