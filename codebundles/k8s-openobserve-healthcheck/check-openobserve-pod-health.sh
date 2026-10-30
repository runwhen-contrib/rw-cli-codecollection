#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Inspects OpenObserve Pods for instability: non-Running phases,
# CrashLoopBackOff, failed readiness, and high container restart counts.
#
# Required env: CONTEXT, NAMESPACE
# Optional: OBJECT_NAME, KUBERNETES_DISTRIBUTION_BINARY, OPENOBSERVE_POD_RESTART_THRESHOLD
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBERNETES_DISTRIBUTION_BINARY="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
KBIN="$KUBERNETES_DISTRIBUTION_BINARY"
RESTART_THRESHOLD="${OPENOBSERVE_POD_RESTART_THRESHOLD:-5}"
OUTPUT_FILE="${OUTPUT_FILE:-openobserve_pod_issues.json}"
issues_json='[]'
: >"$OUTPUT_FILE.tmp"

echo "--- OpenObserve pod stability in namespace ${NAMESPACE} (context ${CONTEXT}) ---"

pods=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get pods -o json 2>/dev/null \
  | jq -c '[.items[] | select(.metadata.name | test("openobserve"; "i"))]' 2>/dev/null || echo "[]")

count=$(echo "$pods" | jq -r 'length' 2>/dev/null || echo 0)
echo "OpenObserve pods found: ${count}"

echo "$pods" | jq -c '.[]' 2>/dev/null | while IFS= read -r pod; do
  name=$(echo "$pod" | jq -r '.metadata.name')
  phase=$(echo "$pod" | jq -r '.status.phase // "Unknown"')
  node=$(echo "$pod" | jq -r '.spec.nodeName // "unscheduled"')
  container_statuses=$(echo "$pod" | jq -c '[.status.containerStatuses[]?]' 2>/dev/null || echo "[]")
  echo "Pod ${name}: phase=${phase} node=${node}"

  if [[ "$phase" != "Running" ]]; then
    echo "Result: Pod ${name} is in phase ${phase}."
    jq -n --arg name "$name" --arg phase "$phase" --arg node "$node" \
      --arg title "OpenObserve pod \`${name}\` is not Running (phase: ${phase})" \
      --arg details "Pod ${name} in namespace ${NAMESPACE} is in phase ${phase} (node: ${node}). It is not serving traffic." \
      --argjson severity 3 \
      --arg next_steps "Run 'kubectl describe pod ${name} -n ${NAMESPACE}' and 'kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp' to find why the pod is stuck." \
      '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
  fi

  echo "$container_statuses" | jq -c '.[]' 2>/dev/null | while IFS= read -r st; do
    cname=$(echo "$st" | jq -r '.name // ""')
    restarts=$(echo "$st" | jq -r '.restartCount // 0')
    ready=$(echo "$st" | jq -r '.ready')
    waiting_reason=$(echo "$st" | jq -r '.state.waiting.reason // ""')
    terminated_reason=$(echo "$st" | jq -r '.state.terminated.reason // ""')

    if [[ "$waiting_reason" == "CrashLoopBackOff" || "$terminated_reason" == "CrashLoopBackOff" ]]; then
      echo "Result: Container ${cname} in pod ${name} is in CrashLoopBackOff."
      jq -n --arg name "$name" --arg cname "$cname" --arg restarts "$restarts" \
        --arg title "OpenObserve container \`${cname}\` in pod \`${name}\` is in CrashLoopBackOff" \
        --arg details "Container ${cname} in pod ${name} is crash-looping (restartCount=${restarts}). The process is failing to start repeatedly." \
        --argjson severity 3 \
        --arg next_steps "Check the container logs ('kubectl logs ${name} -c ${cname} -n ${NAMESPACE} --previous') for the startup error and validate config via the OpenObserve storage-config task." \
        '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
    fi

    if [[ "$ready" == "false" && "$phase" == "Running" ]]; then
      echo "Result: Container readiness probe failing for pod ${name}."
      jq -n --arg name "$name" --arg cname "$cname" \
        --arg title "OpenObserve container \`${cname}\` in pod \`${name}\` is not ready" \
        --arg details "Container ${cname} (pod ${name}) is Running but its readiness probe is failing; traffic is not being routed to it." \
        --argjson severity 3 \
        --arg next_steps "Inspect readiness probe configuration and container logs. API reads may still work while workload is degraded." \
        '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
    fi

    if [[ "${restarts:-0}" -ge "$RESTART_THRESHOLD" ]]; then
      echo "Result: Container ${cname} in pod ${name} has high restart count (${restarts})."
      jq -n --arg name "$name" --arg cname "$cname" --arg restarts "$restarts" \
        --arg title "OpenObserve container \`${cname}\` in pod \`${name}\` has ${restarts} restarts" \
        --arg details "Container ${cname} in pod ${name} has restarted ${restarts} times (threshold: ${RESTART_THRESHOLD}). Repeated restarts indicate instability." \
        --argjson severity 2 \
        --arg next_steps "Check container logs for OOMKills, config errors, or failing health checks. Consider bumping memory limits or fixing the underlying error." \
        '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
    fi
  done
done

if [[ -s "$OUTPUT_FILE.tmp" ]]; then
  issues_json=$(jq -s . "$OUTPUT_FILE.tmp" 2>/dev/null || echo '[]')
elif [[ -f "$OUTPUT_FILE.tmp" ]]; then
  issues_json='[]'
fi
rm -f "$OUTPUT_FILE.tmp"

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "OpenObserve pod stability check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"