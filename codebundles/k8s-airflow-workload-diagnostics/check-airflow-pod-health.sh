#!/usr/bin/env bash
# Evaluates Airflow-labeled pods for phase, Ready condition, restarts, and termination reasons.
set -euo pipefail
set -x

: "${CONTEXT:?}" "${NAMESPACE:?}"

OUTPUT_FILE="${OUTPUT_FILE:-check_airflow_pod_health_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
LABEL_SEL="${AIRFLOW_LABEL_SELECTOR:-app.kubernetes.io/name=airflow}"
RESTART_WARN="${AIRFLOW_RESTART_WARN_THRESHOLD:-10}"

if ! pods_json=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL}" -o json 2>/dev/null); then
  echo '[{"title":"Cannot list Airflow pods","details":"kubectl get pods failed","severity":4,"next_steps":"Verify RBAC and label selector AIRFLOW_LABEL_SELECTOR."}]' | jq . > "$OUTPUT_FILE"
  echo "kubectl get pods failed."
  exit 0
fi

issues_json=$(echo "$pods_json" | jq --arg ns "$NAMESPACE" --arg rw "$RESTART_WARN" '
  [ .items[]? |
    .metadata.name as $name |
    (.status.phase // "") as $phase |
    ([.status.conditions[]? | select(.type == "Ready") | .status] | first // "Unknown") as $ready |
    ([.status.containerStatuses[]? | .restartCount // 0] | add) as $restarts |
    (if ($phase != "Running" and $phase != "Succeeded") then
      [{
        "title": ("Pod `" + $name + "` phase " + $phase + " in `" + $ns + "`"),
        "details": ("Pod phase is " + $phase + " (expected Running for active workloads)."),
        "severity": 3,
        "next_steps": "Describe the pod and check scheduling, image pull, and init containers."
      }]
    else [] end) +
    (if ($ready == "False" and $phase == "Running") then
      [{
        "title": ("Pod `" + $name + "` not Ready in `" + $ns + "`"),
        "details": "Ready condition is False while pod is Running.",
        "severity": 3,
        "next_steps": "Check readiness probes, failing containers, and recent events."
      }]
    else [] end) +
    (if ($restarts > ($rw | tonumber)) then
      [{
        "title": ("High restart count in pod `" + $name + "` in `" + $ns + "`"),
        "details": ("Total container restarts: " + ($restarts | tostring)),
        "severity": 2,
        "next_steps": "Inspect container exit reasons and logs for crash loops."
      }]
    else [] end) +
    ([.status.containerStatuses[]? |
      .name as $cname |
      (.lastState.terminated.reason // "") as $reason |
      select($reason == "OOMKilled" or $reason == "Error" or $reason == "ContainerCannotRun") |
      {
        "title": ("Container `" + $cname + "` in `" + $name + "` terminated: " + $reason),
        "details": ("Last termination reason: " + $reason),
        "severity": (if $reason == "OOMKilled" then 4 else 3 end),
        "next_steps": "Review memory limits and application logs for this container."
      }
    ])
  ] | flatten
')

echo "$issues_json" > "$OUTPUT_FILE"

echo "Checked $(echo "$pods_json" | jq '.items | length') pod(s) with label ${LABEL_SEL}."
