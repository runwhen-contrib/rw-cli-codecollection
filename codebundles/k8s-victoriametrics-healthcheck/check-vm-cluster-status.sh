#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# When cluster mode applies, queries vmselect cluster status JSON and flags problems.
# Respects VM_DEPLOYMENT_MODE: single | cluster | auto
# -----------------------------------------------------------------------------

: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

KUBECTL="${KUBERNETES_DISTRIBUTION_BINARY:-kubectl}"
OUTPUT_FILE="${OUTPUT_FILE:-vm_cluster_status_issues.json}"
MODE="${VM_DEPLOYMENT_MODE:-auto}"
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

if [[ "$MODE" == "single" ]]; then
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  echo "Skipped cluster status (VM_DEPLOYMENT_MODE=single). Wrote $OUTPUT_FILE"
  exit 0
fi

if ! pods_json=$("$KUBECTL" get pods -n "$NAMESPACE" --context "$CONTEXT" "${LABEL_ARGS[@]}" -o json 2>/dev/null); then
  append_issue "Cannot list pods for cluster status in \`${NAMESPACE}\`" "kubectl get pods failed." 4 "Verify kube access."
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  exit 0
fi

vmselect_pod=$(echo "$pods_json" | jq -r '
  [.items[] |
    select(.status.phase=="Running") |
    select(
      ((.metadata.labels["app.kubernetes.io/component"] // "") == "vmselect")
      or ((.metadata.name // "") | test("vmselect"; "i"))
    ) |
    .metadata.name
  ] | first // empty')

if [[ -z "$vmselect_pod" ]]; then
  if [[ "$MODE" == "cluster" ]]; then
    append_issue "No vmselect pod found in \`${NAMESPACE}\`" "VM_DEPLOYMENT_MODE=cluster but no running vmselect pod matched." 3 "Verify VictoriaMetrics cluster install and labels."
  fi
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  echo "No vmselect pod for cluster status. Wrote $OUTPUT_FILE"
  exit 0
fi

STATUS_URLS=(
  "http://127.0.0.1:8481/api/v1/status/cluster"
  "http://127.0.0.1:8481/prometheus/api/v1/status/cluster"
)

raw=""
for url in "${STATUS_URLS[@]}"; do
  raw=""
  raw=$("$KUBECTL" exec -n "$NAMESPACE" --context "$CONTEXT" "$vmselect_pod" -- \
    sh -c "(wget -qO- --timeout=5 \"$url\" 2>/dev/null) || (curl -sS --max-time 5 \"$url\" 2>/dev/null)" 2>/dev/null || true)
  if [[ -n "$raw" ]] && echo "$raw" | jq -e . >/dev/null 2>&1; then
    break
  fi
  raw=""
done

if [[ -z "$raw" ]] || ! echo "$raw" | jq -e . >/dev/null 2>&1; then
  append_issue "Cluster status API unreachable from \`${vmselect_pod}\`" "Could not fetch valid JSON from vmselect (tried /api/v1/status/cluster on port 8481). Path may differ by VictoriaMetrics version." 3 "Confirm version-specific cluster status URL in https://docs.victoriametrics.com/"
  echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
  exit 0
fi

compact=$(echo "$raw" | jq -c . 2>/dev/null | head -c 4000)

if echo "$raw" | jq -r '.. | strings? | .' 2>/dev/null | grep -qiE 'unhealthy|dead|offline'; then
  append_issue "vmselect cluster status may report degraded storage or nodes" "${compact}" 3 "Review vmstorage pods, network paths from vmselect to vmstorage, and VictoriaMetrics cluster troubleshooting docs."
fi

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
echo "Cluster status check completed. Results saved to $OUTPUT_FILE"
