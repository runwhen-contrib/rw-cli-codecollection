#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Scans recent container logs on VictoriaMetrics pods for error/panic/fatal lines.
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="${OUTPUT_FILE:-vm_recent_error_logs_issues.json}"
LOG_TAIL="${VM_LOG_TAIL_LINES:-120}"
LOG_SINCE="${VM_LOG_SINCE:-15m}"
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
  append_issue "Cannot list pods for log scan in \`${NAMESPACE}\`" "kubectl get pods failed." 4 "Verify kube access."
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  exit 0
fi

mapfile -t all_pods < <(echo "$pods_json" | jq -c '.items[]')
for row in "${all_pods[@]:-}"; do
  [[ -z "${row:-}" ]] && continue
  echo "$row" | jq -e '
    select(
      ((.metadata.labels["app.kubernetes.io/name"] // "") | test("victoria-metrics|vmselect|vminsert|vmstorage|vmagent"; "i"))
      or ((.metadata.labels["app.kubernetes.io/component"] // "") | test("vmselect|vminsert|vmstorage|vmagent|single-binary"; "i"))
      or ((.metadata.name // "") | test("vmselect|vminsert|vmstorage|vmagent|victoria-metrics"; "i"))
    )
  ' >/dev/null 2>&1 || continue

  pname=$(echo "$row" | jq -r '.metadata.name')
  phase=$(echo "$row" | jq -r '.status.phase // ""')
  [[ "$phase" != "Running" ]] && continue

  containers=$(echo "$row" | jq -r '.spec.containers[].name')
  while IFS= read -r cname; do
    [[ -z "$cname" ]] && continue
    if ! logs=$("$KUBECTL" logs -n "$NAMESPACE" --context "$CONTEXT" "$pname" -c "$cname" --tail="$LOG_TAIL" --since="$LOG_SINCE" 2>/dev/null); then
      continue
    fi
    matches=$(echo "$logs" | grep -iE '(^|[^a-z])(ERROR|panic|fatal|FATAL|PANIC)' | grep -viE 'level=info' | head -15 || true)
    if [[ -n "$matches" ]]; then
      mtrunc="${matches:0:1800}"
      append_issue "Error signatures in logs for \`${pname}\` container \`${cname}\`" "${mtrunc}" 2 "kubectl logs ${pname} -n ${NAMESPACE} -c ${cname} --context ${CONTEXT} --tail=200; correlate with ingestion/query failures."
    fi
  done <<<"$containers"
done

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Log scan completed. Results saved to $OUTPUT_FILE"
