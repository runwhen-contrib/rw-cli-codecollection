#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Lists degraded boxes, failed drives, offline nodes, and active VMS alarms.
# -----------------------------------------------------------------------------

OUTPUT_FILE="degraded_components_output.json"
REPORT_FILE="degraded_components_report.txt"

source "$(dirname "$0")/vast-vms-common.sh"

issues_json="$(vast_init_issues)"
alarm_count=0
report="Degraded components and alerts for \`${VAST_CLUSTER_NAME}\`\n"

if ! _vast_load_credentials; then
  issues_json="$(vast_api_error_issue "$issues_json" "credentials" "missing vast_vms_credentials")"
  echo "$issues_json" > "$OUTPUT_FILE"
  echo -e "$report" > "$REPORT_FILE"
  exit 0
fi

if alarms_text="$(vast_prometheus_get "alarms" 2>alarms.err)"; then
  active_alarms="$(echo "$alarms_text" | awk '
    $0 !~ /^#/ && $2 != "0" && $2 != "0.0" {
      print $0
    }
  ' | head -30)"
  alarm_count="$(echo "$active_alarms" | grep -c . || true)"
  report+="Active alarm metrics lines: ${alarm_count}\n"
  if [[ "$alarm_count" -gt 0 ]]; then
    issues_json="$(vast_append_issue "$issues_json" \
      "Active VMS Alarms on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
      "Prometheus alarms exporter reports ${alarm_count} active alarm metric(s):\n${active_alarms}" \
      "1" \
      "Review Alarms panel in VMS and remediate highest-severity items first")"
  fi
else
  report+="Note: /api/prometheusmetrics/alarms unavailable; skipping alarm scrape.\n"
fi
rm -f alarms.err

for path in "/api/boxes/" "/api/dboxes/"; do
  if boxes_json="$(vast_api_get "$path" 2>/tmp/boxes.err)"; then
    degraded="$(echo "$boxes_json" | jq -r '
      (if type == "array" then . elif .results then .results else [.] end)
      | map(select((.state // .status // "ONLINE") | ascii_upcase | test("DEGRADED|FAILED|OFFLINE|ERROR")))
      | map("\(.name // .title // .id // "box") state=\(.state // .status)")
      | .[]
    ' 2>/dev/null || true)"
    if [[ -n "$degraded" ]]; then
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        issues_json="$(vast_append_issue "$issues_json" \
          "Degraded Box on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
          "Box from ${path} reports: ${line}" \
          "1" \
          "Inspect box hardware in VMS and engage VAST support if state persists")"
        report+="Degraded box: ${line}\n"
      done <<< "$degraded"
    fi
  fi
done
rm -f /tmp/boxes.err

offline_nodes=0
for entry in "CNode:/api/cnodes/" "DNode:/api/dnodes/"; do
  label="${entry%%:*}"
  api_path="${entry#*:}"
  if nodes_json="$(vast_api_get "$api_path" 2>/tmp/node.err)"; then
    count="$(echo "$nodes_json" | jq '
      (if type == "array" then . elif .results then .results else [.] end)
      | map(select((.state // .status // "ACTIVE") | ascii_upcase | test("OFFLINE|FAILED|INACTIVE|DISABLED|ERROR")))
      | length
    ' 2>/dev/null || echo 0)"
    offline_nodes=$((offline_nodes + count))
    if [[ "$count" -gt 0 ]]; then
      sample="$(echo "$nodes_json" | jq -r '
        (if type == "array" then . elif .results then .results else [.] end)
        | map(select((.state // .status // "ACTIVE") | ascii_upcase | test("OFFLINE|FAILED|INACTIVE|DISABLED|ERROR")))
        | .[0] | "\(.name // .hostname // .id // "node") state=\(.state // .status)"
      ' 2>/dev/null || echo unknown)"
      issues_json="$(vast_append_issue "$issues_json" \
        "Offline ${label}(s) on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
        "${count} ${label}(s) offline or failed (example: ${sample}). Partial cluster failure may impact all tenants." \
        "1" \
        "Restore offline nodes or replace failed hardware; verify cluster quorum in VMS")"
      report+="${count} offline ${label}(s).\n"
    fi
  fi
done
rm -f /tmp/node.err

if [[ "$offline_nodes" -eq 0 && "$alarm_count" -eq 0 ]]; then
  report+="No degraded boxes, offline nodes, or active alarms detected.\n"
fi

echo "$issues_json" > "$OUTPUT_FILE"
echo -e "$report" > "$REPORT_FILE"
echo -e "$report"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
