#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS: CONTEXT, CSI_NAMESPACE
# OPTIONAL: XPRT_PENDING_THRESHOLD (default 100)
# Analyzes csi_node_nfs_xprt_* metrics for congestion and unhealthy VIPs.
# Writes JSON array to nfs_xprt_issues.json
# -----------------------------------------------------------------------------
: "${CONTEXT:?Must set CONTEXT}"
: "${CSI_NAMESPACE:?Must set CSI_NAMESPACE}"

OUTPUT_FILE="nfs_xprt_issues.json"
XPRT_PENDING_THRESHOLD="${XPRT_PENDING_THRESHOLD:-100}"
NODE_METRICS_PORT="${NODE_METRICS_PORT:-9090}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=vast-csi-common.sh
source "${SCRIPT_DIR}/vast-csi-common.sh"

issues_json='[]'
metrics_body=""

print_report() {
  { set +x; } 2>/dev/null || true
  echo
  echo "=== NFS xprt metrics (namespace '${CSI_NAMESPACE}', threshold pending=${XPRT_PENDING_THRESHOLD}) ==="
  if [[ -n "$metrics_body" ]]; then
    echo "$metrics_body" | grep -E '^csi_node_nfs_xprt' | head -n 30 || echo "  (no csi_node_nfs_xprt_* lines found)"
  else
    echo "  No metrics retrieved."
  fi
}
trap print_report EXIT

fetch_node_metrics() {
  local pods_json pod body
  pods_json=$(find_csi_node_pods)
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    body=$(curl_pod_metrics "$pod" "${CSI_NAMESPACE}" "$NODE_METRICS_PORT")
    if [[ -n "$body" ]] && echo "$body" | grep -q 'csi_node_nfs_xprt'; then
      echo "$body"
      return 0
    fi
  done < <(echo "$pods_json" | jq -r '.items[].metadata.name // empty')

  local svc
  svc=$(find_metrics_services | jq -r '[.[] | select(.name | test("node"; "i")) | .name][0] // empty')
  if [[ -n "$svc" ]]; then
    body=$(curl_service_metrics "$svc" "${CSI_NAMESPACE}" "$NODE_METRICS_PORT")
    [[ -n "$body" ]] && echo "$body" && return 0
  fi
  return 1
}

if ! metrics_body=$(fetch_node_metrics); then
  issues_json=$(append_issue "$issues_json" \
    "NFS transport metrics unavailable from VAST CSI node pods" \
    "Could not retrieve csi_node_nfs_xprt_* metrics from ${CSI_NAMESPACE} on context ${CONTEXT}." \
    3 \
    "Enable node metrics and ensure VIP connections are established. Metrics export only while VIPs are connected.")
  write_issues "$OUTPUT_FILE" "$issues_json"
  exit 0
fi

# Unhealthy transports
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  dest=$(echo "$line" | sed -n 's/.*destination="\([^"]*\)".*/\1/p')
  issues_json=$(append_issue "$issues_json" \
    "Unhealthy NFS transport to VIP \`${dest:-unknown}\` on CSI node" \
    "Metric line: ${line}" \
    3 \
    "Verify VIP reachability from worker nodes, check network ACLs, and inspect VMS cluster health for the destination VIP.")
done < <(echo "$metrics_body" | awk '/^csi_node_nfs_xprt_unhealthy\{/{if ($NF >= 1) print}' || true)

# Congested state
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  dest=$(echo "$line" | sed -n 's/.*destination="\([^"]*\)".*/\1/p')
  pending=$(echo "$metrics_body" | awk -v d="$dest" '
    /^csi_node_nfs_xprt_pending_requests\{/ {
      if ($0 ~ "destination=\"" d "\"" && $NF >= '"${XPRT_PENDING_THRESHOLD}"') { print $NF; exit }
    }')
  details="Congested transport detected. Line: ${line}"
  if [[ -n "${pending:-}" ]]; then
    details="${details} pending_requests=${pending} (threshold ${XPRT_PENDING_THRESHOLD})."
  fi
  issues_json=$(append_issue "$issues_json" \
    "NFS transport congestion toward VIP \`${dest:-unknown}\`" \
    "$details" \
    3 \
    "Investigate network congestion between workers and VAST VIPs. Review tenant QoS limits and workload I/O patterns.")
done < <(echo "$metrics_body" | awk '/^csi_node_nfs_xprt_congested_state\{/{if ($NF >= 1) print}' || true)

# Pending requests threshold without congestion flag
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  val=$(echo "$line" | awk '{print $NF}')
  dest=$(echo "$line" | sed -n 's/.*destination="\([^"]*\)".*/\1/p')
  if [[ "${val%%.*}" =~ ^[0-9]+$ ]] && [[ "${val%%.*}" -gt "${XPRT_PENDING_THRESHOLD}" ]]; then
    if ! echo "$issues_json" | jq -e --arg d "${dest:-unknown}" '.[] | select(.title | contains($d))' >/dev/null 2>&1; then
      issues_json=$(append_issue "$issues_json" \
        "High pending NFS requests toward VIP \`${dest:-unknown}\`" \
        "csi_node_nfs_xprt_pending_requests=${val} exceeds threshold ${XPRT_PENDING_THRESHOLD}. Line: ${line}" \
        3 \
        "Check for slow VMS responses or network latency. Consider scaling tenant QoS or reducing concurrent mount pressure.")
    fi
  fi
done < <(echo "$metrics_body" | awk '/^csi_node_nfs_xprt_pending_requests\{/{print}' || true)

# No transports connected at all
xprt_total=$(echo "$metrics_body" | awk '/^csi_node_nfs_xprt_total /{print $NF; exit}')
xprt_connected=$(echo "$metrics_body" | awk '/^csi_node_nfs_xprt_connected /{print $NF; exit}')
if [[ "${xprt_total:-1}" == "0.0" || "${xprt_total:-1}" == "0" ]]; then
  issues_json=$(append_issue "$issues_json" \
    "No NFS transports registered on VAST CSI node metrics" \
    "csi_node_nfs_xprt_total=${xprt_total:-0} indicates no active VIP connections." \
    2 \
    "Confirm StorageClass endpoint/VIP configuration and that workloads have attempted mounts on this node.")
fi

write_issues "$OUTPUT_FILE" "$issues_json"
