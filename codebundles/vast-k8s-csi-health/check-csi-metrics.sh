#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, CSI_NAMESPACE
# OPTIONAL: RPC_ERROR_RATE_THRESHOLD (default 5)
# Scrapes CSI node (9090) and controller (9091) /metrics for RPC failures.
# Writes JSON array to csi_metrics_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${CSI_NAMESPACE:?Must set CSI_NAMESPACE}"

OUTPUT_FILE="csi_metrics_issues.json"
RPC_ERROR_RATE_THRESHOLD="${RPC_ERROR_RATE_THRESHOLD:-5}"
NODE_METRICS_PORT="${NODE_METRICS_PORT:-9090}"
CONTROLLER_METRICS_PORT="${CONTROLLER_METRICS_PORT:-9091}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-csi-common.sh
source "${SCRIPT_DIR}/vast-csi-common.sh"

issues_json='[]'
metrics_body=""

print_report() {
  { set +x; } 2>/dev/null || true
  echo
  echo "=== VAST CSI metrics probe (context '${CONTEXT}', namespace '${CSI_NAMESPACE}') ==="
  echo "RPC error rate threshold: ${RPC_ERROR_RATE_THRESHOLD}%"
  if [[ -n "$metrics_body" ]]; then
    echo "$metrics_body" | head -n 40
    echo "... (truncated)"
  else
    echo "  No metrics payload retrieved."
  fi
  echo
  if [[ -s "$OUTPUT_FILE" ]]; then
    jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
  fi
}
trap print_report EXIT

fetch_metrics() {
  local role="$1"
  local port="$2"
  local pods_json svc_json body

  pods_json=$([ "$role" == "node" ] && find_csi_node_pods || find_csi_controller_pods)
  local pod
  pod=$(echo "$pods_json" | jq -r '.items[0].metadata.name // empty')
  if [[ -n "$pod" ]]; then
    body=$(curl_pod_metrics "$pod" "${CSI_NAMESPACE}" "$port")
    if [[ -n "$body" ]]; then
      echo "$body"
      return 0
    fi
  fi

  svc_json=$(find_metrics_services)
  local svc
  svc=$(echo "$svc_json" | jq -r --arg role "$role" '
    [.[] | select(.name | test($role; "i")) | .name][0] // empty
  ')
  if [[ -z "$svc" ]]; then
    svc=$(echo "$svc_json" | jq -r '.[0].name // empty')
  fi
  if [[ -n "$svc" ]]; then
    body=$(curl_service_metrics "$svc" "${CSI_NAMESPACE}" "$port")
    if [[ -n "$body" ]]; then
      echo "$body"
      return 0
    fi
  fi
  return 1
}

analyze_rpc_metrics() {
  local role="$1"
  local body="$2"
  [[ -z "$body" ]] && return

  local total failed rate slow_ops
  total=$(echo "$body" | awk '/^csi_plugin_operations_total\{/{sum+=$NF} END{print sum+0}')
  failed=$(echo "$body" | awk '/^csi_plugin_operations_total\{[^}]*grpc_code="(Internal|Unknown|Unavailable|DeadlineExceeded|ResourceExhausted|Aborted|FailedPrecondition)"/{sum+=$NF} END{print sum+0}')
  if [[ "${total:-0}" -gt 0 ]]; then
    rate=$(awk "BEGIN {printf \"%.2f\", (${failed:-0}/${total})*100}")
    if awk "BEGIN {exit !(${rate} > ${RPC_ERROR_RATE_THRESHOLD})}"; then
      issues_json=$(append_issue "$issues_json" \
        "Elevated CSI RPC error rate on ${role} metrics (context \`${CONTEXT}\`)" \
        "csi_plugin_operations_total failures=${failed} of ${total} (${rate}% > threshold ${RPC_ERROR_RATE_THRESHOLD}%)." \
        3 \
        "Inspect ${role} pod logs in ${CSI_NAMESPACE}. Correlate with VMS health and NFS xprt congestion metrics.")
    fi
  fi

  slow_ops=$(echo "$body" | awk '/^csi_plugin_operations_seconds\{/{if ($NF > 5) c++} END{print c+0}')
  if [[ "${slow_ops:-0}" -gt 0 ]]; then
    issues_json=$(append_issue "$issues_json" \
      "Slow CSI RPC operations detected on ${role} metrics" \
      "Found ${slow_ops} csi_plugin_operations_seconds samples exceeding 5s in ${CSI_NAMESPACE}." \
        3 \
        "Check VMS latency, network path to VIPs, and node CPU pressure on CSI ${role} pods.")
  fi

  if ! echo "$body" | grep -q '^csi_plugin_operations_total'; then
    issues_json=$(append_issue "$issues_json" \
      "CSI plugin operation metrics missing from ${role} endpoint" \
      "Metrics endpoint responded but csi_plugin_operations_total was not present; metrics may be disabled." \
      4 \
      "Enable metrics in the VAST CSI Helm chart (metrics.enabled=true) and verify ServiceMonitor or headless metrics Services.")
  fi
}

node_metrics=""
controller_metrics=""

if node_metrics=$(fetch_metrics "node" "$NODE_METRICS_PORT"); then
  metrics_body+=$'\n'"# Node metrics (port ${NODE_METRICS_PORT})"$'\n'"${node_metrics}"
  analyze_rpc_metrics "node" "$node_metrics"
else
  issues_json=$(append_issue "$issues_json" \
    "Unable to scrape VAST CSI node metrics in namespace \`${CSI_NAMESPACE}\`" \
    "Could not reach /metrics on node pods (port ${NODE_METRICS_PORT}) or metrics Services." \
    3 \
    "Enable node metrics in Helm values. Verify pod exec/network access from the RunWhen execution environment.")
fi

if controller_metrics=$(fetch_metrics "controller" "$CONTROLLER_METRICS_PORT"); then
  metrics_body+=$'\n'"# Controller metrics (port ${CONTROLLER_METRICS_PORT})"$'\n'"${controller_metrics}"
  analyze_rpc_metrics "controller" "$controller_metrics"
else
  issues_json=$(append_issue "$issues_json" \
    "Unable to scrape VAST CSI controller metrics in namespace \`${CSI_NAMESPACE}\`" \
    "Could not reach /metrics on controller pods (port ${CONTROLLER_METRICS_PORT}) or metrics Services." \
    3 \
    "Enable controller metrics in Helm values and confirm the controller metrics Service has endpoints.")
fi

write_issues "$OUTPUT_FILE" "$issues_json"
