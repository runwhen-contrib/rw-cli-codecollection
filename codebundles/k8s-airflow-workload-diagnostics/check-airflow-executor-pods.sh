#!/usr/bin/env bash
# Summarizes Celery/Kubernetes executor related pods: pending reasons and resource hints from describe.
set -euo pipefail
set -x

: "${CONTEXT:?}" "${NAMESPACE:?}"

OUTPUT_FILE="${OUTPUT_FILE:-check_airflow_executor_pods_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
LABEL_SEL="${AIRFLOW_LABEL_SELECTOR:-app.kubernetes.io/name=airflow}"

if ! pods_json=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL}" -o json 2>/dev/null); then
  echo '[{"title":"Cannot list Airflow pods","details":"kubectl get pods failed","severity":4,"next_steps":"Verify RBAC."}]' | jq . > "$OUTPUT_FILE"
  exit 0
fi

executor_json=$(echo "$pods_json" | jq '[.items[]? | select(
  (.metadata.name | test("worker|celery|kubernetes|executor"; "i")) or
  (.metadata.labels["app.kubernetes.io/component"]? // "" | test("worker|celery"; "i"))
)]')

issues_json=$(echo "$executor_json" | jq --arg ns "$NAMESPACE" '
  [ .[]? |
    .metadata.name as $n |
    (.status.phase // "") as $ph |
    (if $ph == "Pending" then
      [{
        "title": ("Executor-related pod `" + $n + "` Pending in `" + $ns + "`"),
        "details": ((.status.conditions // []) | map(.message // "") | join("; ")),
        "severity": 3,
        "next_steps": "Describe the pod for scheduling and volume mount errors; check cluster capacity."
      }]
    else [] end) +
    ([.status.containerStatuses[]? |
      .name as $c |
      (.lastState.terminated.reason // "") as $reason |
      select($reason == "OOMKilled") |
      {
        "title": ("OOMKilled in executor pod `" + $n + "` container `" + $c + "`"),
        "details": "Last termination: OOMKilled",
        "severity": 4,
        "next_steps": "Raise memory limits or reduce task concurrency for workers."
      }
    ])
  ] | flatten
')

echo "$issues_json" > "$OUTPUT_FILE"

echo "Executor-related pods:"
echo "$executor_json" | jq -r '.[] | [.metadata.name, .status.phase] | @tsv' || true
