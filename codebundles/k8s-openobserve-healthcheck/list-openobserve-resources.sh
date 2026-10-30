#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Discovers OpenObserve resources in the namespace: workloads (Deployment /
# StatefulSet whose name contains "openobserve"), Services, PVCs, Secrets, and
# ConfigMaps. Adds a topology summary to the report and raises an issue when no
# OpenObserve resources are found (wrong namespace or name).
#
# Required env: CONTEXT, NAMESPACE
# Optional: OBJECT_NAME (name of the generated SLX's matched workload), KUBERNETES_DISTRIBUTION_BINARY
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBERNETES_DISTRIBUTION_BINARY="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
KBIN="$KUBERNETES_DISTRIBUTION_BINARY"
OUTPUT_FILE="${OUTPUT_FILE:-openobserve_resources_issues.json}"
issues_json='[]'

echo "--- OpenObserve resource discovery in namespace ${NAMESPACE} (context ${CONTEXT}) ---"

# Workloads (Deployment/StatefulSet) whose name contains "openobserve"
workloads=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get deploy,sts -o json 2>/dev/null \
  | jq -r '[.items[] | select(.metadata.name | test("openobserve"; "i")) | {kind: .kind, name: .metadata.name, replicas: (.spec.replicas // .spec.replicas // 0), ready: (.status.readyReplicas // 0)}]' 2>/dev/null || echo "[]")

workload_count=$(echo "$workloads" | jq -r 'length' 2>/dev/null || echo 0)
svc_count=0; pvc_count=0; secret_count=0; cm_count=0
svc_names=""; pvc_names=""; secret_names=""; cm_names=""

svc_names=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get svc -o json 2>/dev/null \
  | jq -r '[.items[] | select(.metadata.name | test("openobserve"; "i")) | .metadata.name] | join(", ")' 2>/dev/null || true)
[ -n "$svc_names" ] && svc_count=$(echo "$svc_names" | awk -F', ' '{print NF}')

pvc_names=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get pvc -o json 2>/dev/null \
  | jq -r '[.items[] | select(.metadata.name | test("openobserve"; "i")) | .metadata.name] | join(", ")' 2>/dev/null || true)
[ -n "$pvc_names" ] && pvc_count=$(echo "$pvc_names" | awk -F', ' '{print NF}')

secret_names=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get secrets -o json 2>/dev/null \
  | jq -r '[.items[] | select(.metadata.name | test("openobserve"; "i")) | .metadata.name] | join(", ")' 2>/dev/null || true)
[ -n "$secret_names" ] && secret_count=$(echo "$secret_names" | awk -F', ' '{print NF}')

cm_names=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get cm -o json 2>/dev/null \
  | jq -r '[.items[] | select(.metadata.name | test("openobserve"; "i")) | .metadata.name] | join(", ")' 2>/dev/null || true)
[ -n "$cm_names" ] && cm_count=$(echo "$cm_names" | awk -F', ' '{print NF}')

echo "Workloads (containing 'openobserve'):"
echo "$workloads" | jq -r '.[] | "  \(.kind) \(.name) ready=\(.ready)/\(.replicas)"'
echo "Services: ${svc_names:-<none>}"
echo "PersistentVolumeClaims: ${pvc_names:-<none>}"
echo "Secrets: ${secret_names:-<none>}"
echo "ConfigMaps: ${cm_names:-<none>}"

if [[ "$workload_count" -eq 0 ]]; then
  echo "Result: No OpenObserve workloads found in namespace '${NAMESPACE}'."
  issues_json=$(echo "$issues_json" | jq \
    --arg title "No OpenObserve workloads found in namespace \`${NAMESPACE}\`" \
    --arg details "No Deployment or StatefulSet whose name contains 'openobserve' exists in namespace ${NAMESPACE} (context ${CONTEXT}). Check the namespace/name or confirm the workload was deployed." \
    --argjson severity 3 \
    --arg next_steps "Verify NAMESPACE is correct, confirm the OpenObserve Helm release was installed into this namespace, or adjust the generation-rule name match (pattern 'openobserve')." \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": $severity,
       "next_steps": $next_steps
     }]')
fi

if [[ -n "${OBJECT_NAME:-}" ]]; then
  object_found=$(echo "$workloads" | jq -r --arg n "$OBJECT_NAME" '[.[] | select(.name == $n)] | length' 2>/dev/null || echo 0)
  if [[ "$object_found" -eq 0 ]]; then
    echo "Result: Matched workload '${OBJECT_NAME}' was not found in namespace '${NAMESPACE}'."
    issues_json=$(echo "$issues_json" | jq \
      --arg title "OpenObserve workload \`${OBJECT_NAME}\` not found in namespace \`${NAMESPACE}\`" \
      --arg details "Discovery for this SLX targeted workload ${OBJECT_NAME}, but no Deployment/StatefulSet with that name exists (or it was scaled/renamed)." \
      --argjson severity 3 \
      --arg next_steps "Confirm the workload name, re-run discovery, or delete the stale SLX if the workload was permanently removed." \
      '. += [{
         "title": $title,
         "details": $details,
         "severity": $severity,
         "next_steps": $next_steps
       }]')
  fi
fi

echo "$issues_json" | jq . >"$OUTPUT_FILE"
echo "OpenObserve resource discovery complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"