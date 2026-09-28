#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Probes /health on VictoriaMetrics component pods via kubectl exec (localhost).
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="${OUTPUT_FILE:-vm_http_health_issues.json}"
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

guess_port() {
  local name="$1"
  local comp="${2:-}"
  local lc="${name}${comp}"
  case "$lc" in
    *vmselect*) echo 8481 ;;
    *vm-insert*|*vminsert*) echo 8480 ;;
    *vmstorage*|*vm-storage*) echo 8482 ;;
    *vmagent*) echo 8429 ;;
    *victoria-metrics*|*vmsingle*|*single*)
      echo 8429
      ;;
    *) echo 8429 ;;
  esac
}

http_get() {
  local pod="$1"
  local port="$2"
  if ! out=$("$KUBECTL" exec -n "$NAMESPACE" --context "$CONTEXT" "$pod" -- \
    sh -c "(command -v wget >/dev/null && wget -qO- --timeout=4 http://127.0.0.1:${port}/health) || (command -v curl >/dev/null && curl -sS --max-time 4 http://127.0.0.1:${port}/health) || echo __EXEC_FAIL__" 2>/dev/null); then
    echo "__EXEC_FAIL__"
    return
  fi
  echo "$out"
}

if ! pods_json=$("$KUBECTL" get pods -n "$NAMESPACE" --context "$CONTEXT" "${LABEL_ARGS[@]}" -o json 2>/dev/null); then
  append_issue "Cannot list pods for HTTP health in \`${NAMESPACE}\`" "kubectl get pods failed." 4 "Verify kube access."
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

  comp=$(echo "$row" | jq -r '.metadata.labels["app.kubernetes.io/component"] // ""')
  port=$(guess_port "$pname" "$comp")

  body=$(http_get "$pname" "$port" || echo "__EXEC_FAIL__")
  if [[ "$body" == "__EXEC_FAIL__" ]] || [[ -z "$body" ]]; then
    append_issue "HTTP /health probe failed for pod \`${pname}\` (port ${port})" "kubectl exec did not return a response from http://127.0.0.1:${port}/health." 3 "Confirm the container image includes wget/curl and the process listens on port ${port}."
    continue
  fi
  if echo "$body" | grep -qiE 'ok|healthy'; then
    continue
  fi
  # Some builds return plain body; treat non-empty short response as OK if no error
  if [[ ${#body} -lt 400 ]] && ! echo "$body" | grep -qiE 'error|fail'; then
    continue
  fi
  append_issue "Unexpected /health body from pod \`${pname}\`" "Port ${port}. Body (truncated): $(echo "$body" | head -c 300)" 2 "Review application logs for ${pname} and VictoriaMetrics version-specific health output."
done

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "HTTP health check completed. Results saved to $OUTPUT_FILE"
