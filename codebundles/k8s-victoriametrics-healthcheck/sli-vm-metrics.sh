#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lightweight JSON metrics for sli.robot: readiness_score and pvc_score (0 or 1).
# Env: CONTEXT, NAMESPACE, KUBERNETES_DISTRIBUTION_BINARY, VM_LABEL_SELECTOR (optional)
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
LABEL_ARGS=()
if [[ -n "${VM_LABEL_SELECTOR:-}" ]]; then
  LABEL_ARGS=(-l "${VM_LABEL_SELECTOR}")
fi

pods_json=$("$KUBECTL" get pods -n "$NAMESPACE" --context "$CONTEXT" "${LABEL_ARGS[@]}" -o json 2>/dev/null || echo '{"items":[]}')

unready=$(
  echo "$pods_json" | jq '[.items[] |
    select(
      ((.metadata.labels["app.kubernetes.io/name"] // "") | test("victoria-metrics|vmselect|vminsert|vmstorage|vmagent"; "i"))
      or ((.metadata.labels["app.kubernetes.io/component"] // "") | test("vmselect|vminsert|vmstorage|vmagent|single-binary"; "i"))
      or ((.metadata.name // "") | test("vmselect|vminsert|vmstorage|vmagent|victoria-metrics"; "i"))
    ) |
    select(.status.phase=="Running") |
    select(.status.conditions[]? | select(.type=="Ready" and .status=="False"))
  ] | length'
)

[[ "$unready" -eq 0 ]] && readiness_score=1 || readiness_score=0

pvc_json=$("$KUBECTL" get pvc -n "$NAMESPACE" --context "$CONTEXT" -o json 2>/dev/null || echo '{"items":[]}')

bad_pvc=$(
  echo "$pvc_json" | jq '[.items[] |
    select(
      ((.metadata.name // "") | test("vmstorage|vmselect|vminsert|victoria-metrics|vm-"; "i"))
      or ((.metadata.labels["app.kubernetes.io/name"] // "") | test("victoria-metrics|vmstorage"; "i"))
    ) |
    select(.status.phase != "Bound")
  ] | length'
)

[[ "$bad_pvc" -eq 0 ]] && pvc_score=1 || pvc_score=0

jq -n --argjson readiness_score "$readiness_score" --argjson pvc_score "$pvc_score" \
  '{readiness_score: $readiness_score, pvc_score: $pvc_score}'
