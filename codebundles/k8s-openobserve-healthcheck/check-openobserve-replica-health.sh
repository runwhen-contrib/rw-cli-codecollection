#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Compares ready vs desired replicas for each OpenObserve Deployment/StatefulSet
# in the namespace. Flags workloads that are not fully ready or scaled to zero.
#
# Required env: CONTEXT, NAMESPACE
# Optional: KUBERNETES_DISTRIBUTION_BINARY
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBERNETES_DISTRIBUTION_BINARY="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
KBIN="$KUBERNETES_DISTRIBUTION_BINARY"
OUTPUT_FILE="${OUTPUT_FILE:-openobserve_replica_issues.json}"
issues_json='[]'
: >"$OUTPUT_FILE.tmp"

echo "--- OpenObserve workload replica health in namespace ${NAMESPACE} (context ${CONTEXT}) ---"

items=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get deploy,sts -o json 2>/dev/null \
  | jq -c '[.items[] | select(.metadata.name | test("openobserve"; "i"))]' 2>/dev/null || echo "[]")

count=$(echo "$items" | jq -r 'length' 2>/dev/null || echo 0)
if [[ "$count" -eq 0 ]]; then
  echo "No OpenObserve workloads found; nothing to evaluate."
fi

echo "$items" | jq -c '.[]' 2>/dev/null | while IFS= read -r wl; do
  kind=$(echo "$wl" | jq -r '.kind')
  name=$(echo "$wl" | jq -r '.metadata.name')
  desired=$(echo "$wl" | jq -r '((.spec.replicas // 0))')
  ready=$(echo "$wl" | jq -r '((.status.readyReplicas // 0))')
  updated=$(echo "$wl" | jq -r '((.status.updatedReplicas // 0))')
  available=$(echo "$wl" | jq -r '((.status.availableReplicas // 0))')
  echo "$kind ${name}: desired=${desired} ready=${ready} updated=${updated} available=${available}"

  # ready >= desired and desired >= 1 is fully healthy. desired == 0 is a
  # scaled-to-zero workload which the spec treats as a flag (severity 3).
  if [[ "$desired" -eq 0 ]]; then
    if [[ "$ready" -eq 0 ]]; then
      echo "Result: ${kind} ${name} is scaled to zero replicas."
      jq -n --arg kind "$kind" --arg name "$name" \
        --arg title "${kind} \`${name}\` is scaled to zero replicas" \
        --arg details "${kind} ${name} has 0 desired replicas (ready=${ready}). This is often intentional but leaves the service unavailable; confirm it matches expectations." \
        --argjson severity 3 \
        --arg next_steps "If this is unexpected, scale the workload back up (kubectl scale). If intentional, acknowledge the scaled-to-zero state to avoid alert spam." \
        '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
    fi
  elif [[ "$ready" -lt "$desired" ]]; then
    echo "Result: ${kind} ${name} has ${ready}/${desired} replicas ready."
    jq -n --arg kind "$kind" --arg name "$name" --arg ready "$ready" --arg desired "$desired" --arg updated "$updated" \
      --arg title "${kind} \`${name}\` is not fully ready (${ready}/${desired})" \
      --arg details "${kind} ${name} has ${ready}/${desired} ready replicas (updated=${updated}). Not all replicas are accepting traffic." \
      --argjson severity 3 \
      --arg next_steps "Check pod status with 'kubectl get pods -n ${NAMESPACE}' and inspect events for the unready pods. Look for image pull, resource, or probe failures." \
      '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
  else
    echo "Result: ${kind} ${name} is fully ready (${ready}/${desired})."
  fi
done

if [[ -s "$OUTPUT_FILE.tmp" ]]; then
  issues_json=$(jq -s . "$OUTPUT_FILE.tmp" 2>/dev/null || echo '[]')
  rm -f "$OUTPUT_FILE.tmp"
else
  issues_json='[]'
  rm -f "$OUTPUT_FILE.tmp"
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "OpenObserve replica health check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"