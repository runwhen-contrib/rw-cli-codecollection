#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Discovers VictoriaMetrics-labeled workloads and reports unhealthy pods or
# rollout conditions. Writes JSON array issues to OUTPUT_FILE.
# Env: CONTEXT, NAMESPACE, KUBERNETES_DISTRIBUTION_BINARY, VM_LABEL_SELECTOR (optional)
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="${OUTPUT_FILE:-vm_workload_readiness_issues.json}"
issues_json='[]'

LABEL_ARGS=()
if [[ -n "${VM_LABEL_SELECTOR:-}" ]]; then
  LABEL_ARGS=(-l "${VM_LABEL_SELECTOR}")
fi

append_issue() {
  local title="$1"
  local details="$2"
  local severity="$3"
  local next_steps="$4"
  issues_json=$(echo "$issues_json" | jq \
    --arg title "$title" \
    --arg details "$details" \
    --argjson severity "$severity" \
    --arg next_steps "$next_steps" \
    '. += [{title: $title, details: $details, severity: $severity, next_steps: $next_steps}]')
}

if ! pods_json=$("$KUBECTL" get pods -n "$NAMESPACE" --context "$CONTEXT" "${LABEL_ARGS[@]}" -o json 2>/dev/null); then
  append_issue "Cannot list pods in namespace \`${NAMESPACE}\`" "kubectl get pods failed; verify context, kubeconfig, and RBAC." 4 "Confirm kubeconfig secret, context name, and namespace exist."
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  echo "Wrote $OUTPUT_FILE"
  exit 0
fi

is_vm_pod() {
  echo "$1" | jq -e '
    select(
      ((.metadata.labels["app.kubernetes.io/name"] // "") | test("victoria-metrics|vmselect|vminsert|vmstorage|vmagent"; "i"))
      or ((.metadata.labels["app.kubernetes.io/name"] // "") | test("^vm-"; "i"))
      or ((.metadata.labels["app.kubernetes.io/component"] // "") | test("vmselect|vminsert|vmstorage|vmagent|single-binary"; "i"))
      or ((.metadata.name // "") | test("vmselect|vminsert|vmstorage|vmagent|victoria-metrics"; "i"))
    )
  ' >/dev/null 2>&1
}

mapfile -t all_pods < <(echo "$pods_json" | jq -c '.items[]')
for row in "${all_pods[@]:-}"; do
  is_vm_pod "$row" || continue
  pname=$(echo "$row" | jq -r '.metadata.name')
  phase=$(echo "$row" | jq -r '.status.phase // "Unknown"')
  if [[ "$phase" == "Pending" ]]; then
    append_issue "Pod \`${pname}\` stuck Pending in \`${NAMESPACE}\`" "VictoriaMetrics workload pod not scheduled." 3 "kubectl describe pod ${pname} -n ${NAMESPACE} --context ${CONTEXT}"
    continue
  fi
  while IFS= read -r cs; do
    [[ -z "$cs" ]] && continue
    wr=$(echo "$cs" | jq -r '.state.waiting.reason // empty')
    tr=$(echo "$cs" | jq -r '.state.terminated.reason // empty')
    cname=$(echo "$cs" | jq -r '.name // "container"')
    if [[ "$wr" =~ ^(CrashLoopBackOff|ImagePullBackOff|ErrImagePull|CreateContainerConfigError)$ ]]; then
      append_issue "Container \`${cname}\` unhealthy on \`${pname}\` (${wr})" "Namespace \`${NAMESPACE}\`, phase=${phase}." 3 "kubectl logs ${pname} -n ${NAMESPACE} --context ${CONTEXT} -c ${cname}"
    elif [[ "$tr" =~ ^(OOMKilled|Error)$ ]]; then
      append_issue "Container \`${cname}\` terminated (${tr}) on \`${pname}\`" "Namespace \`${NAMESPACE}\`." 3 "Review logs and resource limits for ${pname}."
    fi
  done < <(echo "$row" | jq -c '.status.containerStatuses[]? // empty')
  if echo "$row" | jq -e '.status.conditions[]? | select(.type=="Ready" and .status=="False")' >/dev/null 2>&1; then
    if [[ "$phase" == "Running" ]]; then
      nr=$(echo "$row" | jq -r '.status.conditions[]? | select(.type=="Ready") | .reason // "NotReady"')
      append_issue "Pod \`${pname}\` not Ready in \`${NAMESPACE}\`" "Ready condition: ${nr}" 3 "Check readiness probes and dependencies for ${pname}."
    fi
  fi
done

for kind in deployment statefulset daemonset; do
  if ! res_json=$("$KUBECTL" get "$kind" -n "$NAMESPACE" --context "$CONTEXT" "${LABEL_ARGS[@]}" -o json 2>/dev/null); then
    continue
  fi
  mapfile -t witems < <(echo "$res_json" | jq -c '.items[] |
    select(
      ((.metadata.labels["app.kubernetes.io/name"] // "") | test("victoria-metrics|vmselect|vminsert|vmstorage|vmagent"; "i"))
      or ((.metadata.labels["app.kubernetes.io/component"] // "") | test("vmselect|vminsert|vmstorage|vmagent|single-binary"; "i"))
      or ((.metadata.name // "") | test("vmselect|vminsert|vmstorage|vmagent|victoria"; "i"))
    )')
  for item in "${witems[@]:-}"; do
    [[ -z "${item:-}" ]] && continue
    iname=$(echo "$item" | jq -r '.metadata.name')
    while IFS= read -r cond; do
      [[ -z "$cond" ]] && continue
      ctype=$(echo "$cond" | jq -r '.type')
      cstat=$(echo "$cond" | jq -r '.status')
      creason=$(echo "$cond" | jq -r '.reason // ""')
      cmsg=$(echo "$cond" | jq -r '.message // ""')
      if [[ "$cstat" == "False" ]]; then
        if [[ "$ctype" == "Available" ]]; then
          append_issue "${kind}/${iname} is not Available (${creason})" "${cmsg}" 3 "kubectl describe ${kind} ${iname} -n ${NAMESPACE} --context ${CONTEXT}"
        elif [[ "$ctype" == "Progressing" ]] && echo "${creason}${cmsg}" | grep -qiE 'ProgressDeadlineExceeded|ReplicaFailure|Failed|error'; then
          append_issue "${kind}/${iname} rollout stalled (${creason})" "${cmsg}" 3 "kubectl describe ${kind} ${iname} -n ${NAMESPACE} --context ${CONTEXT}"
        fi
      fi
    done < <(echo "$item" | jq -c '.status.conditions[]? // empty')
  done
done

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
