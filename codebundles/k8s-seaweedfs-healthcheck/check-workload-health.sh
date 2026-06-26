#!/usr/bin/env bash
set -euo pipefail
set -x
# Verifies SeaweedFS StatefulSets/Deployments replica health and warning events.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="workload_health_issues.json"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  { set +x; } 2>/dev/null || true
  echo "=== SeaweedFS workload health (${NAMESPACE}) ==="
  if [[ -f "$COMPONENT_MAP_FILE" ]]; then
    jq -r '
      (.statefulsets + .deployments)
      | .[]
      | "  \(.name)  ready=\(.ready)/\(.replicas)  component=\(.component)"
    ' "$COMPONENT_MAP_FILE" 2>/dev/null || true
  fi
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

map_json=$(swf_discover_components)
echo "$map_json" >"$COMPONENT_MAP_FILE"

while IFS= read -r wl; do
  [[ -z "$wl" ]] && continue
  name=$(echo "$wl" | jq -r '.name')
  kind="statefulset"
  if echo "$map_json" | jq -e --arg n "$name" '.deployments[] | select(.name==$n)' >/dev/null; then
    kind="deployment"
  fi
  want=$(echo "$wl" | jq -r '.replicas')
  ready=$(echo "$wl" | jq -r '.ready')
  if [[ "$want" =~ ^[0-9]+$ ]] && [[ "$ready" =~ ^[0-9]+$ ]] && [[ "$want" -gt 0 ]] && [[ "$ready" -lt "$want" ]]; then
    swf_add_issue \
      "SeaweedFS ${kind} \`${name}\` is not fully Ready" \
      "readyReplicas=${ready}, desired=${want}" \
      2 \
      "kubectl describe ${kind} ${name} -n ${NAMESPACE} --context ${CONTEXT}"
  fi

  pods_json=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
    | jq --arg n "$name" '{items: [.items[] | select(.metadata.name | startswith($n))]}' || echo '{"items":[]}')

  while IFS= read -r pline; do
    [[ -z "$pline" ]] && continue
    pname=$(echo "$pline" | jq -r '.name')
    phase=$(echo "$pline" | jq -r '.phase')
    crash=$(echo "$pline" | jq -r '.crash')
    pending=$(echo "$pline" | jq -r '.pending')
    if [[ "$crash" == "true" ]]; then
      swf_add_issue \
        "SeaweedFS pod \`${pname}\` is in CrashLoopBackOff" \
        "Workload ${name}, phase=${phase}" \
        2 \
        "kubectl logs ${pname} -n ${NAMESPACE} --context ${CONTEXT} --previous"
    elif [[ "$pending" == "true" ]]; then
      swf_add_issue \
        "SeaweedFS pod \`${pname}\` is pending scheduling" \
        "Workload ${name}, phase=${phase}" \
        3 \
        "kubectl describe pod ${pname} -n ${NAMESPACE} --context ${CONTEXT}"
    fi
  done < <(echo "$pods_json" | jq -c '.items[] | {
    name: .metadata.name,
    phase: (.status.phase // "Unknown"),
    crash: ([.status.containerStatuses[]? | .state.waiting.reason? // empty] | any(. == "CrashLoopBackOff")),
    pending: (.status.phase == "Pending")
  }')

  events=$("${KUBECTL}" get events -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
    | jq --arg n "$name" '[.items[] | select(.type=="Warning") | select(.involvedObject.name | contains($n)) | .message] | unique | .[0:3] | join("; ")' || echo "")
  if [[ -n "$events" && "$events" != "null" ]]; then
    swf_add_issue \
      "Recent Warning events for SeaweedFS workload \`${name}\`" \
      "$events" \
      3 \
      "kubectl get events -n ${NAMESPACE} --context ${CONTEXT} --field-selector involvedObject.name=${name}"
  fi
done < <(echo "$map_json" | jq -c '.statefulsets[], .deployments[]')

swf_write_issues "$OUTPUT_FILE"
