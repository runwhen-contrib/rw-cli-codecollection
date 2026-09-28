#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Inspects CNode/DNode and SSD/SCM hardware health from REST and Prometheus.
# -----------------------------------------------------------------------------

OUTPUT_FILE="node_hardware_health_output.json"
REPORT_FILE="node_hardware_health_report.txt"

source "$(dirname "$0")/vast-vms-common.sh"

issues_json="$(vast_init_issues)"
report="Node hardware health for \`${VAST_CLUSTER_NAME}\`\n"

if ! _vast_load_credentials; then
  issues_json="$(vast_api_error_issue "$issues_json" "credentials" "missing vast_vms_credentials")"
  echo "$issues_json" > "$OUTPUT_FILE"
  echo -e "$report" > "$REPORT_FILE"
  exit 0
fi

check_nodes() {
  local kind="$1"
  local path="$2"
  local nodes_json=""
  if ! nodes_json="$(vast_api_get "$path" 2>"/tmp/${kind}.err")"; then
    report+="Warning: ${kind} REST API unavailable.\n"
    return 0
  fi
  local bad
  bad="$(echo "$nodes_json" | jq -r '
    (if type == "array" then . elif .results then .results else [.] end)
    | map(select((.state // .status // "ACTIVE") | ascii_upcase | test("OFFLINE|FAILED|INACTIVE|DISABLED|ERROR")))
    | map("\(.name // .hostname // .id // "unknown") state=\(.state // .status)")
    | .[]
  ' 2>/dev/null || true)"
  if [[ -n "$bad" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      issues_json="$(vast_append_issue "$issues_json" \
        "Unhealthy ${kind} on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
        "${kind} reports unhealthy state: ${line}" \
        "2" \
        "Inspect ${kind} in VMS, verify hardware LEDs/cabling, and follow VAST support guidance for replacement")"
      report+="Unhealthy ${kind}: ${line}\n"
    done <<< "$bad"
  else
    count="$(echo "$nodes_json" | jq 'if type == "array" then length elif .results then (.results|length) else 1 end' 2>/dev/null || echo 0)"
    report+="All ${count} ${kind}(s) appear healthy via REST.\n"
  fi
}

check_nodes "CNode" "/api/cnodes/"
check_nodes "DNode" "/api/dnodes/"

if devices_text="$(vast_prometheus_get "devices" 2>devices.err)"; then
  failed_devices="$(echo "$devices_text" | awk '
    $0 !~ /^#/ && ($0 ~ /state/ || $0 ~ /status/) && ($0 ~ /failed|error|offline|inactive|0$/) {
      print $0
    }
  ' | head -20)"
  if [[ -n "$failed_devices" ]]; then
    issues_json="$(vast_append_issue "$issues_json" \
      "SSD/SCM Hardware Faults on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
      "Prometheus devices metrics indicate failed or unhealthy media:\n${failed_devices}" \
      "2" \
      "Review DBox device status in VMS and replace failed SSD/SCM modules")"
    report+="Device metric faults detected (see issues).\n"
  else
    report+="No failed SSD/SCM indicators in /api/prometheusmetrics/devices.\n"
  fi
else
  report+="Note: /api/prometheusmetrics/devices unavailable on this VAST version.\n"
fi
rm -f devices.err /tmp/CNode.err /tmp/DNode.err

echo "$issues_json" > "$OUTPUT_FILE"
echo -e "$report" > "$REPORT_FILE"
echo -e "$report"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
