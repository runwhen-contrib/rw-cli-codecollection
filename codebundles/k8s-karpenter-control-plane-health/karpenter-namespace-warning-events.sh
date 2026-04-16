#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Aggregates Warning events in the Karpenter namespace within RW_LOOKBACK_WINDOW.
# Writes JSON array to warning_events_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${KARPENTER_NAMESPACE:?Must set KARPENTER_NAMESPACE}"

OUTPUT_FILE="warning_events_issues.json"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
RW_LOOKBACK_WINDOW="${RW_LOOKBACK_WINDOW:-30m}"

parse_minutes() {
  local t="${1:-30m}"
  if [[ "$t" =~ ^([0-9]+)m$ ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$t" =~ ^([0-9]+)h$ ]]; then echo $((${BASH_REMATCH[1]} * 60))
  elif [[ "$t" =~ ^[0-9]+$ ]]; then echo "$t"
  else echo "30"
  fi
}

MINUTES=$(parse_minutes "$RW_LOOKBACK_WINDOW")
THRESHOLD_TIME=$(date -u -d "@$(($(date +%s) - MINUTES * 60))" +"%Y-%m-%dT%H:%M:%SZ")

if ! ev_json=$("${KUBECTL}" get events -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" \
  --field-selector type=Warning -o json 2>/dev/null); then
  jq -n \
    --arg title "Cannot list events in namespace \`${KARPENTER_NAMESPACE}\`" \
    --arg details "kubectl get events failed; check permissions and context." \
    --argjson severity 3 \
    --arg next_steps "Verify RBAC for events in this namespace." \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]' >"$OUTPUT_FILE"
  exit 0
fi

echo "$ev_json" | jq \
  --arg th "$THRESHOLD_TIME" \
  --arg ns "$KARPENTER_NAMESPACE" \
  '
  [.items[]
    | select((.lastTimestamp // .eventTime // "1970-01-01T00:00:00Z") > $th)
    | select(.involvedObject.kind != null and .involvedObject.name != null)
    | select(
        (.involvedObject.name | test("karpenter"; "i"))
        or (.message | test("karpenter|nodeclaim|nodepool|ec2nodeclass|awsnodetemplate|machine|webhook"; "i"))
      )
  ]
  | group_by(.involvedObject.kind + "/" + .involvedObject.name)
  | map({
      title: ("Warning events (" + (length | tostring) + ") for " + .[0].involvedObject.kind + " `\(.[0].involvedObject.name)` in `" + $ns + "`"),
      details: ([.[].message] | unique | .[0:8] | join("\n")),
      severity: (if ([.[].message] | join(" ") | test("fail|error|denied|blocked|timeout"; "i")) then 3 else 4 end),
      next_steps: ("kubectl describe " + .[0].involvedObject.kind + " " + .[0].involvedObject.name + " -n " + $ns)
    })
  | unique_by(.title)
  ' >"$OUTPUT_FILE"

echo "Wrote ${OUTPUT_FILE}"
