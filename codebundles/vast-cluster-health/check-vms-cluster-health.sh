#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   VAST_VMS_ENDPOINT, VAST_CLUSTER_NAME
# OPTIONAL:
#   CAPACITY_THRESHOLD, CRITICAL_CAPACITY_THRESHOLD
#   VAST_VMS_CREDENTIALS_FILE / VAST_VMS_CREDENTIALS_JSON
#
# Queries /api/prometheusmetrics/vms_state and cluster REST status.
# -----------------------------------------------------------------------------

OUTPUT_FILE="vms_cluster_health_output.json"
REPORT_FILE="vms_cluster_health_report.txt"

source "$(dirname "$0")/vast-vms-common.sh"

issues_json="$(vast_init_issues)"
report="VMS cluster health check for \`${VAST_CLUSTER_NAME}\` at ${VAST_VMS_ENDPOINT}\n"

if ! _vast_load_credentials; then
  issues_json="$(vast_api_error_issue "$issues_json" "credentials" "missing vast_vms_credentials")"
  echo "$issues_json" > "$OUTPUT_FILE"
  echo -e "$report" > "$REPORT_FILE"
  exit 0
fi

vms_state_text=""
if vms_state_text="$(vast_prometheus_get "vms_state" 2>vms_state.err)"; then
  vms_state="$(vast_prometheus_gauge "$vms_state_text" "vms_state")"
  if [[ -z "$vms_state" ]]; then
    vms_state="$(vast_prometheus_gauge "$vms_state_text" "vast_vms_state")"
  fi
  report+="VMS state metric: ${vms_state:-unknown} (1=CLUSTERED, 0=DEGRADED)\n"
  if [[ "$vms_state" == "0" ]]; then
    issues_json="$(vast_append_issue "$issues_json" \
      "VAST Cluster \`${VAST_CLUSTER_NAME}\` VMS State is DEGRADED" \
      "Prometheus vms_state gauge reports 0 (DEGRADED). Cluster-wide operations may be impaired." \
      "1" \
      "Review VMS alarms and degraded components; check offline CNodes/DNodes in VMS UI")"
  elif [[ -z "$vms_state" ]]; then
    report+="Warning: vms_state metric not found in exporter response (endpoint may be unavailable on older VAST versions).\n"
  fi
else
  err_msg="$(cat vms_state.err 2>/dev/null || echo unknown)"
  report+="Warning: /api/prometheusmetrics/vms_state unavailable: ${err_msg}\n"
fi
rm -f vms_state.err

clusters_json=""
if clusters_json="$(vast_api_get "/api/clusters/" 2>clusters.err)"; then
  cluster_obj="$(vast_find_cluster_json "$clusters_json" "$VAST_CLUSTER_NAME")"
  if [[ -n "$cluster_obj" ]]; then
    cluster_state="$(echo "$cluster_obj" | jq -r '.state // "UNKNOWN"')"
    enabled="$(echo "$cluster_obj" | jq -r '.enabled // true')"
    report+="Cluster REST state: ${cluster_state}, enabled=${enabled}\n"
    if [[ "$cluster_state" != "ONLINE" && "$cluster_state" != "CLUSTERED" ]]; then
      issues_json="$(vast_append_issue "$issues_json" \
        "VAST Cluster \`${VAST_CLUSTER_NAME}\` State is ${cluster_state}" \
        "Cluster REST API reports state=${cluster_state} (expected ONLINE/CLUSTERED)." \
        "2" \
        "Inspect cluster events in VMS and verify all boxes and nodes are online")"
    fi
    if [[ "$enabled" != "true" ]]; then
      issues_json="$(vast_append_issue "$issues_json" \
        "VAST Cluster \`${VAST_CLUSTER_NAME}\` is Disabled" \
        "Cluster enabled flag is false in VMS REST API." \
        "2" \
        "Re-enable the cluster in VMS if this was not intentional maintenance")"
    fi
  else
    report+="Warning: cluster \`${VAST_CLUSTER_NAME}\` not found in /api/clusters/ response.\n"
  fi
else
  err_msg="$(cat clusters.err 2>/dev/null || echo unknown)"
  issues_json="$(vast_api_error_issue "$issues_json" "cluster status" "$err_msg")"
fi
rm -f clusters.err

health_text=""
if health_text="$(vast_api_get "/health/" 2>health.err)"; then
  health_state="$(echo "$health_text" | jq -r '.state // .status // empty' 2>/dev/null || true)"
  if [[ -n "$health_state" ]]; then
    report+="VMS /health/ status: ${health_state}\n"
    if [[ "$health_state" =~ ^(DEGRADED|UNHEALTHY|ERROR|FAILED)$ ]]; then
      issues_json="$(vast_append_issue "$issues_json" \
        "VAST Cluster \`${VAST_CLUSTER_NAME}\` VMS Health Endpoint Reports ${health_state}" \
        "GET /health/ returned state=${health_state}." \
        "1" \
        "Review VMS health dashboard and active alarms")"
    fi
  fi
else
  report+="Note: /health/ endpoint unavailable (requires VAST 5.4.3+).\n"
fi
rm -f health.err

echo "$issues_json" > "$OUTPUT_FILE"
echo -e "$report" > "$REPORT_FILE"
echo -e "$report"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
