#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Discovers Karpenter controller pods and evaluates readiness, restarts, phases.
# Writes JSON array of issues to controller_pods_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${KARPENTER_NAMESPACE:?Must set KARPENTER_NAMESPACE}"

OUTPUT_FILE="controller_pods_issues.json"
KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
issues_json='[]'

if ! "${KUBECTL}" get ns "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o name &>/dev/null; then
  issues_json=$(echo "$issues_json" | jq -n \
    --arg title "Namespace \`${KARPENTER_NAMESPACE}\` not found in context \`${CONTEXT}\`" \
    --arg details "kubectl cannot read the Karpenter namespace; the controller cannot be assessed." \
    --argjson severity 3 \
    --arg next_steps "Confirm KARPENTER_NAMESPACE matches your install (default: karpenter). Verify kubeconfig and RBAC." \
    '[{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  echo "Namespace missing; wrote $OUTPUT_FILE"
  exit 0
fi

pods_json=$("${KUBECTL}" get pods -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" \
  -l 'app.kubernetes.io/name=karpenter' -o json 2>/dev/null || echo '{"items":[]}')

sel_count=$(echo "$pods_json" | jq '.items | length')
if [[ "$sel_count" -eq 0 ]]; then
  pods_json=$("${KUBECTL}" get pods -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o json)
  pods_json=$(echo "$pods_json" | jq '{items: [.items[] | select(
      (.metadata.labels["app.kubernetes.io/name"]? == "karpenter") or
      ((.metadata.labels["app.kubernetes.io/instance"]? // "") | test("karpenter")) or
      (.metadata.name | test("karpenter"))
    )]}')
fi

pcount=$(echo "$pods_json" | jq '.items | length')
if [[ "$pcount" -eq 0 ]]; then
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No Karpenter controller pods found in namespace \`${KARPENTER_NAMESPACE}\`" \
    --arg details "No pods matched app.kubernetes.io/name=karpenter or name patterns for Karpenter." \
    --argjson severity 3 \
    --arg next_steps "Verify the Helm release or install. If using custom labels, document overrides in workspace config." \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

while IFS= read -r line; do
  name=$(echo "$line" | jq -r '.name')
  phase=$(echo "$line" | jq -r '.phase')
  ready=$(echo "$line" | jq -r '.ready')
  restarts=$(echo "$line" | jq -r '.restarts')
  crash=$(echo "$line" | jq -r '.crash')
  if [[ "$crash" == "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Karpenter pod \`${name}\` is in CrashLoopBackOff" \
      --arg details "Pod phase=${phase}, ready=${ready}, containerRestartSum=${restarts}" \
      --argjson severity 2 \
      --arg next_steps "Inspect logs: kubectl logs -n ${KARPENTER_NAMESPACE} ${name} --context ${CONTEXT}; check IAM, webhook CA, and CRD versions." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  elif [[ "$ready" != "true" ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "Karpenter pod \`${name}\` is not Ready" \
      --arg details "Phase=${phase}, restarts=${restarts}" \
      --argjson severity 3 \
      --arg next_steps "Describe pod and events: kubectl describe pod -n ${KARPENTER_NAMESPACE} ${name} --context ${CONTEXT}" \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi
  if [[ "${restarts}" =~ ^[0-9]+$ ]] && [[ "$restarts" -gt 10 ]]; then
    issues_json=$(echo "$issues_json" | jq \
      --arg title "High container restart count on Karpenter pod \`${name}\`" \
      --arg details "Total restarts across containers: ${restarts}" \
      --argjson severity 2 \
      --arg next_steps "Review recent logs and node pressure; check for OOM or config reload loops." \
      '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
  fi
done < <(echo "$pods_json" | jq -c '.items[] | {
  name: .metadata.name,
  phase: (.status.phase // "Unknown"),
  ready: ((.status.conditions // []) | map(select(.type=="Ready")) | .[0].status // "False"),
  restarts: ([.status.containerStatuses[]? | .restartCount // 0] | add),
  crash: ([.status.containerStatuses[]? | .state.waiting.reason? // empty] | map(select(. == "CrashLoopBackOff")) | length > 0)
}')

# Deployment replica alignment (best-effort)
deps=$("${KUBECTL}" get deploy -n "${KARPENTER_NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null || echo '{"items":[]}')
while IFS= read -r dline; do
  [[ -z "$dline" ]] && continue
  dname=$(echo "$dline" | jq -r '.name')
  want=$(echo "$dline" | jq -r '.desired')
  have=$(echo "$dline" | jq -r '.ready')
  if [[ "$want" =~ ^[0-9]+$ ]] && [[ "$have" =~ ^[0-9]+$ ]] && [[ "$want" -gt 0 ]] && [[ "$have" -lt "$want" ]]; then
    if echo "$dline" | jq -e 'select(.name | test("karpenter"))' >/dev/null; then
      issues_json=$(echo "$issues_json" | jq \
        --arg title "Karpenter Deployment \`${dname}\` is not fully Ready" \
        --arg details "readyReplicas=${have}, desired=${want}" \
        --argjson severity 3 \
        --arg next_steps "kubectl describe deploy -n ${KARPENTER_NAMESPACE} ${dname} --context ${CONTEXT}" \
        '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
    fi
  fi
done < <(echo "$deps" | jq -c '.items[] | select(.metadata.name | test("karpenter")) | {name: .metadata.name, desired: (.spec.replicas // 0), ready: (.status.readyReplicas // 0)}')

echo "$issues_json" >"$OUTPUT_FILE"
echo "Wrote ${OUTPUT_FILE}"
