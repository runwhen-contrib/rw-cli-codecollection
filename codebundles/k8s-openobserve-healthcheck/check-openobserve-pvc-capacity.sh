#!/usr/bin/env bash
set -uo pipefail
# -----------------------------------------------------------------------------
# Lists the PVCs backing OpenObserve (capacity, status, reclaim policy) and
# flags unbound volumes or volumes approaching capacity using kubectl-level
# data only. Never execs 'df' or inspects storage from inside a container.
#
# Required env: CONTEXT, NAMESPACE
# Optional: PVC_USAGE_THRESHOLD_PERCENT (default 80)
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"
KUBERNETES_DISTRIBUTION_BINARY="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
KBIN="$KUBERNETES_DISTRIBUTION_BINARY"
THRESHOLD="${PVC_USAGE_THRESHOLD_PERCENT:-80}"
OUTPUT_FILE="${OUTPUT_FILE:-openobserve_pvc_issues.json}"
issues_json='[]'
: >"$OUTPUT_FILE.tmp"

echo "--- OpenObserve PVC capacity report in namespace ${NAMESPACE} (context ${CONTEXT}) ---"

pvcs=$("$KBIN" --context "$CONTEXT" -n "$NAMESPACE" get pvc -o json 2>/dev/null \
  | jq -c '[.items[] | select(.metadata.name | test("openobserve"; "i"))]' 2>/dev/null || echo "[]")

count=$(echo "$pvcs" | jq -r 'length' 2>/dev/null || echo 0)
echo "OpenObserve PVCs found: ${count}"
if [[ "$count" -eq 0 ]]; then
  echo "No OpenObserve-named PVCs found. If OpenObserve uses S3/object storage (ZO_LOCAL_MODE=false), no PVCs are expected."
fi

echo "$pvcs" | jq -c '.[]' 2>/dev/null | while IFS= read -r pvc; do
  name=$(echo "$pvc" | jq -r '.metadata.name')
  phase=$(echo "$pvc" | jq -r '.status.phase // "Pending"')
  capacity=$(echo "$pvc" | jq -r '.status.capacity.storage // ""')
  requested=$(echo "$pvc" | jq -r '.spec.resources.requests.storage // ""')
  access_modes=$(echo "$pvc" | jq -r '(.spec.accessModes // []) | join(",")' 2>/dev/null)
  pv_name=$(echo "$pvc" | jq -r '.spec.volumeName // ""')
  reclaim_policy="n/a"
  if [[ -n "$pv_name" && "$pv_name" != "null" ]]; then
    reclaim_policy=$("$KBIN" --context "$CONTEXT" get pv "$pv_name" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || true)
  fi
  echo "PVC ${name}: phase=${phase} capacity=${capacity:-unset} requested=${requested:-unset} accessModes=${access_modes:-none} reclaimPolicy=${reclaim_policy}"

  if [[ "$phase" != "Bound" ]]; then
    echo "Result: PVC ${name} is not bound (phase: ${phase})."
    jq -n --arg name "$name" --arg phase "$phase" --arg requested "$requested" \
      --arg title "OpenObserve PVC \`${name}\` is not bound (phase: ${phase})" \
      --arg details "PVC ${name} in namespace ${NAMESPACE} is in phase ${phase} (requested storage: ${requested:-unset}). Unbound volumes can block pod scheduling and data writes." \
      --argjson severity 3 \
      --arg next_steps "Check StorageClass, quota, and PV availability: 'kubectl describe pvc ${name} -n ${NAMESPACE}'. Ensure a matching PersistentVolume can be provisioned." \
      '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
  fi

  # Capacity-approaching signal (kubectl-level only): when the requested size
  # reaches THRESHOLD percent of the provisioned capacity, flag a warning.
  # True usage is measured by the API storage_metrics task.
  cap_unit=$(echo "$capacity" | grep -oE '[A-Za-z]+' || true)
  req_unit=$(echo "$requested" | grep -oE '[A-Za-z]+' || true)
  cap_val=$(echo "$capacity" | grep -oE '^[0-9]+' || echo 0)
  req_val=$(echo "$requested" | grep -oE '^[0-9]+' || echo 0)
  if [[ -n "$cap_unit" && -n "$req_unit" && "$cap_unit" == "$req_unit" && "$req_val" -gt 0 && "$cap_val" -gt 0 ]]; then
    usage_pct=$(( req_val * 100 / cap_val ))
    echo "  PVC ${name}: request/capacity ratio ~${usage_pct}% (request=${requested}, capacity=${capacity})."
    if [[ "$usage_pct" -ge "$THRESHOLD" ]]; then
      echo "Result: PVC ${name} requested size is ${usage_pct}% of capacity (>= ${THRESHOLD}%)."
      jq -n --arg name "$name" --arg usage "$usage_pct" --arg thresh "$THRESHOLD" \
        --arg title "OpenObserve PVC \`${name}\` approaching capacity (~${usage_pct}%)" \
        --arg details "PVC ${name} has a request of ${requested} against provisioned capacity of ${capacity} (~${usage_pct}%). When data reaches this level, writes to the local store may slow or fail." \
        --argjson severity 2 \
        --arg next_steps "Review OpenObserve storage usage via the storage_metrics task, and consider moving to S3/object storage (ZO_LOCAL_MODE=false) or expanding the volume." \
        '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}' >>"$OUTPUT_FILE.tmp"
    fi
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
echo "OpenObserve PVC capacity check complete. Issues written to $OUTPUT_FILE"
cat "$OUTPUT_FILE"