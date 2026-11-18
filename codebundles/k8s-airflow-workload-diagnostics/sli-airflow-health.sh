#!/usr/bin/env bash
# Lightweight SLI: binary scores for workload readiness, pod readiness, and warning events (Airflow-scoped).
# Prints one JSON object to stdout for sli.robot.
set -euo pipefail

: "${CONTEXT:?}" "${NAMESPACE:?}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
LABEL_SEL="${AIRFLOW_LABEL_SELECTOR:-app.kubernetes.io/name=airflow}"
PREFIX="${AIRFLOW_DEPLOYMENT_NAME_PREFIX:-airflow}"
LW="${RW_LOOKBACK_WINDOW:-1h}"
EVENT_MAX="${AIRFLOW_SLI_EVENT_THRESHOLD:-8}"

if [[ "$LW" =~ ^([0-9]+)h$ ]]; then SEC=$((BASH_REMATCH[1] * 3600))
elif [[ "$LW" =~ ^([0-9]+)m$ ]]; then SEC=$((BASH_REMATCH[1] * 60))
else SEC=3600
fi
CUTOFF=$(date -u -d "@$(( $(date +%s) - SEC ))" +%Y-%m-%dT%H:%M:%SZ)

workload_score=1
if ! labeled_json=$("${KUBECTL}" get deploy,sts,ds -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL}" -o json 2>/dev/null); then
  labeled_json='{"items":[]}'
fi
if ! all_json=$("${KUBECTL}" get deploy,sts,ds -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null); then
  all_json='{"items":[]}'
fi
bad_w=$(echo "$labeled_json" "$all_json" | jq -s --arg prefix "$PREFIX" '
  ((.[0].items // []) + (.[1].items // [] | map(select(.metadata.name | startswith($prefix)))))
  | unique_by(.metadata.uid)
  | map(
      if .kind == "DaemonSet" then
        [(.status.desiredNumberScheduled // 0), (.status.numberReady // 0)]
      elif .kind == "Deployment" or .kind == "StatefulSet" then
        [(.spec.replicas // 0), (.status.readyReplicas // 0)]
      else [0,0] end
    )
  | map(select(.[0] > 0 and .[1] < .[0]))
  | length
')
[[ "${bad_w}" -gt 0 ]] && workload_score=0

pod_score=1
if ! pods_json=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL}" -o json 2>/dev/null); then
  pods_json='{"items":[]}'
fi
bad_p=$(echo "$pods_json" | jq '[.items[]? | select((.status.phase != "Running" and .status.phase != "Succeeded") or ([.status.conditions[]? | select(.type=="Ready") | .status] | first // "False") == "False")] | length')
[[ "${bad_p}" -gt 0 ]] && pod_score=0

event_score=1
if ! ev_json=$("${KUBECTL}" get events -n "${NAMESPACE}" --context "${CONTEXT}" --field-selector type=Warning -o json 2>/dev/null); then
  ev_json='{"items":[]}'
fi
cnt=$(echo "$ev_json" | jq --arg c "$CUTOFF" '[.items[]? | select((.lastTimestamp // .firstTimestamp // "") >= $c)] | length')
[[ "${cnt}" -gt "${EVENT_MAX}" ]] && event_score=0

jq -n \
  --argjson w "$workload_score" \
  --argjson p "$pod_score" \
  --argjson e "$event_score" \
  '{workload: $w, pods: $p, events: $e}'
