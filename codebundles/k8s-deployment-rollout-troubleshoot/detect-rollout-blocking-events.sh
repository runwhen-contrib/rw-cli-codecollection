#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, NAMESPACE, DEPLOYMENT_NAME
# OPTIONAL: EVENT_AGE (default 30m)
# Outputs issues to detect_rollout_blocking_events.json
# -----------------------------------------------------------------------------

: "${KUBERNETES_DISTRIBUTION_BINARY:=kubectl}"
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
: "${DEPLOYMENT_NAME:?Must set DEPLOYMENT_NAME}"
: "${EVENT_AGE:=30m}"

OUTPUT_FILE="detect_rollout_blocking_events.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=k8s-rollout-helpers.sh
source "${SCRIPT_DIR}/k8s-rollout-helpers.sh"

init_issues_json

echo "Detecting rollout blocking events for deployment ${DEPLOYMENT_NAME} (window: ${EVENT_AGE})"

if ! fetch_deployment_json; then
    write_issues "$OUTPUT_FILE"
    exit 0
fi

fetch_deployment_replicasets_json
LATEST_RS=$(get_latest_replicaset_name)
rs_names=$(echo "$REPLICASETS_JSON" | jq -r '.[].metadata.name' | tr '\n' '|')
rs_pattern="${DEPLOYMENT_NAME}|${rs_names%|}"

EVENTS_JSON=$("${K8S_CMD[@]}" get events -o json 2>/dev/null || echo '{"items":[]}')
lookback_seconds=$(parse_duration_to_seconds "$EVENT_AGE")

blocking_reasons="FailedScheduling|FailedCreate|ReplicaFailure|ProgressDeadlineExceeded|FailedMount|FailedAttachVolume|Failed|Error|BackOff|ExceededGracePeriod|EvictionThresholdMet|FailedKillPod|FailedPreStopHook|FailedPostStartHook|SandboxChanged|NetworkNotReady|InspectFailed"

filtered_events=$(echo "$EVENTS_JSON" | jq \
    --arg pattern "$rs_pattern" \
    --arg dep "$DEPLOYMENT_NAME" \
    --argjson lookback "$lookback_seconds" \
    --arg reasons "$blocking_reasons" \
    '[.items[] |
      select(.type == "Warning" or .type == "Error") |
      select(.involvedObject.name | test($dep) or test($pattern)) |
      select((.lastTimestamp // .eventTime // .metadata.creationTimestamp) as $ts |
        ($ts | fromdateiso8601) >= (now - $lookback)) |
      select(.reason | test($reasons; "i"))
    ]')

event_count=$(echo "$filtered_events" | jq 'length')
echo "Found ${event_count} blocking event(s) in the last ${EVENT_AGE}"

if [[ "$event_count" -gt 0 ]]; then
    summary=$(echo "$filtered_events" | jq -r '.[] | "\(.lastTimestamp // .eventTime // .metadata.creationTimestamp) [\(.type)/\(.reason)] \(.involvedObject.kind)/\(.involvedObject.name): \(.message)"' | head -20)
    add_issue "2" \
        "Rollout Blocking Events for Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "${event_count} Warning/Error event(s) in the last ${EVENT_AGE}:\n${summary}" \
        "Address root cause per event type. For pod failures run Inspect New ReplicaSet Pod Failures. For quota/admission issues check cluster limits."
fi

# Cluster-level quota/admission hints
quota_events=$(echo "$EVENTS_JSON" | jq \
    --arg dep "$DEPLOYMENT_NAME" \
    --argjson lookback "$lookback_seconds" \
    '[.items[] |
      select(.message | test("quota|admission|forbidden|exceeded"; "i")) |
      select(.involvedObject.name | test($dep)) |
      select((.lastTimestamp // .eventTime // .metadata.creationTimestamp) as $ts |
        ($ts | fromdateiso8601) >= (now - $lookback))
    ]')

quota_count=$(echo "$quota_events" | jq 'length')
if [[ "$quota_count" -gt 0 ]]; then
    quota_summary=$(echo "$quota_events" | jq -r '.[] | "\(.reason): \(.message)"' | head -10)
    add_issue "3" \
        "Quota or Admission Failures Affecting Deployment \`${DEPLOYMENT_NAME}\` in Namespace \`${NAMESPACE}\`" \
        "${quota_summary}" \
        "Review namespace ResourceQuota and LimitRange. Reduce resource requests or increase quota."
fi

write_issues "$OUTPUT_FILE"
echo "Analysis completed. Results saved to ${OUTPUT_FILE}"
