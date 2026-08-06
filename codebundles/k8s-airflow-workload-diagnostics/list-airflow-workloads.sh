#!/usr/bin/env bash
# Lists Deployments, StatefulSets, and DaemonSets tied to Airflow via label selector
# and optional name prefix; emits issues when replicas are not ready.
set -euo pipefail
set -x

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="${OUTPUT_FILE:-list_airflow_workloads_issues.json}"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
LABEL_SEL="${AIRFLOW_LABEL_SELECTOR:-app.kubernetes.io/name=airflow}"
PREFIX="${AIRFLOW_DEPLOYMENT_NAME_PREFIX:-airflow}"

if ! labeled_json=$("${KUBECTL}" get deploy,sts,ds -n "${NAMESPACE}" --context "${CONTEXT}" -l "${LABEL_SEL}" -o json 2>/dev/null); then
  labeled_json='{"items":[]}'
fi

if ! all_json=$("${KUBECTL}" get deploy,sts,ds -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null); then
  err_msg="kubectl get deploy,sts,ds failed for namespace ${NAMESPACE}"
  echo '[]' | jq \
    --arg title "Cannot list workloads in namespace \`${NAMESPACE}\`" \
    --arg details "${err_msg}" \
    --arg severity "4" \
    --arg next_steps "Verify kubeconfig, context, and RBAC for get/list on apps resources in this namespace." \
    '. + [{
      "title": $title,
      "details": $details,
      "severity": ($severity | tonumber),
      "next_steps": $next_steps
    }]' > "$OUTPUT_FILE"
  echo "$err_msg"
  exit 0
fi

merged_json=$(jq -n --argjson labeled "$labeled_json" --argjson all "$all_json" --arg prefix "$PREFIX" '
  ($labeled.items // []) as $li |
  ($all.items // []) as $ai |
  {items: (($li + ($ai | map(select(.metadata.name | startswith($prefix))))) | unique_by(.metadata.uid))}
')

issues_json=$(echo "$merged_json" | jq --arg ns "$NAMESPACE" '
  [ .items[]? |
    . as $o |
    ($o.kind) as $k |
    ($o.metadata.name) as $n |
    (if $k == "DaemonSet" then
        [($o.status.desiredNumberScheduled // 0), ($o.status.numberReady // 0)]
     elif ($k == "Deployment" or $k == "StatefulSet") then
        [($o.spec.replicas // 0), ($o.status.readyReplicas // 0)]
     else
        [0, 0]
     end) as $pair |
    ($pair[0] | tonumber) as $desired |
    ($pair[1] | tonumber) as $ready |
    select($desired > 0 and $ready < $desired) |
    {
      "title": ($k + " `" + $n + "` not fully ready in `" + $ns + "`"),
      "details": ($k + " " + $n + ": ready " + ($ready | tostring) + " / desired " + ($desired | tostring)),
      "severity": 3,
      "next_steps": ("Inspect pod status, events, and resource limits for " + $n + ".")
    }
  ]
')

echo "$issues_json" > "$OUTPUT_FILE"

echo "Discovered $(echo "$merged_json" | jq '.items | length') Airflow-related workload object(s) (label \`${LABEL_SEL}\` and/or name prefix \`${PREFIX}\`)."
printf '%s\n' "--- Workload summary ---"
echo "$merged_json" | jq -r '.items[]? | [.kind, .metadata.name,
  (if .kind == "DaemonSet" then
    ("ready " + ((.status.numberReady // 0) | tostring) + " / desired " + ((.status.desiredNumberScheduled // 0) | tostring))
  else
    ("ready " + ((.status.readyReplicas // 0) | tostring) + " / desired " + ((.spec.replicas // 0) | tostring))
  end)] | @tsv'
