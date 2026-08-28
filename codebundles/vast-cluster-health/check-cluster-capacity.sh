#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Evaluates physical and logical capacity utilization for the scoped cluster.
# -----------------------------------------------------------------------------

OUTPUT_FILE="cluster_capacity_output.json"
REPORT_FILE="cluster_capacity_report.txt"

source "$(dirname "$0")/vast-vms-common.sh"

issues_json="$(vast_init_issues)"
report="Capacity utilization for \`${VAST_CLUSTER_NAME}\` (threshold=${CAPACITY_THRESHOLD}%, critical=${CRITICAL_CAPACITY_THRESHOLD}%)\n"

if ! _vast_load_credentials; then
  issues_json="$(vast_api_error_issue "$issues_json" "credentials" "missing vast_vms_credentials")"
  echo "$issues_json" > "$OUTPUT_FILE"
  echo -e "$report" > "$REPORT_FILE"
  exit 0
fi

physical_pct=""
logical_pct=""

if clusters_json="$(vast_api_get "/api/clusters/" 2>clusters.err)"; then
  cluster_obj="$(vast_find_cluster_json "$clusters_json" "$VAST_CLUSTER_NAME")"
  if [[ -n "$cluster_obj" ]]; then
    physical_pct="$(echo "$cluster_obj" | jq -r '.physical_space_in_use_percent // empty')"
    logical_pct="$(echo "$cluster_obj" | jq -r '.logical_space_in_use_percent // empty')"
    physical_tb="$(echo "$cluster_obj" | jq -r '.physical_space_in_use_tb // .physical_space_in_use // "n/a"')"
    logical_tb="$(echo "$cluster_obj" | jq -r '.logical_space_in_use_tb // .logical_space_in_use // "n/a"')"
    report+="REST capacity: physical=${physical_pct}% (${physical_tb} TB in use), logical=${logical_pct}% (${logical_tb} TB in use)\n"
  fi
else
  err_msg="$(cat clusters.err 2>/dev/null || echo unknown)"
  issues_json="$(vast_api_error_issue "$issues_json" "cluster capacity" "$err_msg")"
fi
rm -f clusters.err

if [[ -z "$physical_pct" || -z "$logical_pct" ]]; then
  if metrics_text="$(vast_prometheus_get "basic_no_views" 2>metrics.err || vast_prometheus_get "" 2>metrics.err)"; then
    physical_pct="$(vast_prometheus_gauge "$metrics_text" "physical_space_in_use_percent")"
    logical_pct="$(vast_prometheus_gauge "$metrics_text" "logical_space_in_use_percent")"
    if [[ -z "$physical_pct" ]]; then
      physical_used="$(vast_prometheus_gauge "$metrics_text" "physical_space_in_use")"
      physical_total="$(vast_prometheus_gauge "$metrics_text" "physical_space")"
      if [[ -n "$physical_used" && -n "$physical_total" && "$physical_total" != "0" ]]; then
        physical_pct="$(python3 - <<PY
used=float("${physical_used}")
total=float("${physical_total}")
print(round(100.0 * used / total, 2))
PY
)"
      fi
    fi
    report+="Prometheus fallback: physical=${physical_pct:-n/a}%, logical=${logical_pct:-n/a}%\n"
  else
    report+="Warning: could not fetch capacity from REST or Prometheus.\n"
  fi
  rm -f metrics.err
fi

for kind in physical logical; do
  if [[ "$kind" == "physical" ]]; then
    pct="$physical_pct"
  else
    pct="$logical_pct"
  fi
  [[ -z "$pct" || "$pct" == "null" ]] && continue
  report+="${kind} utilization: ${pct}%\n"
  cmp_critical="$(python3 - <<PY
pct=float("${pct}")
crit=float("${CRITICAL_CAPACITY_THRESHOLD}")
warn=float("${CAPACITY_THRESHOLD}")
if pct >= crit:
    print("critical")
elif pct >= warn:
    print("warning")
else:
    print("ok")
PY
)"
  if [[ "$cmp_critical" == "critical" ]]; then
    issues_json="$(vast_append_issue "$issues_json" \
      "Critical ${kind^} Capacity for VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
      "${kind^} capacity utilization is ${pct}% (critical threshold ${CRITICAL_CAPACITY_THRESHOLD}%)." \
      "2" \
      "Expedite capacity expansion, delete stale snapshots, or rebalance tenants before writes fail")"
  elif [[ "$cmp_critical" == "warning" ]]; then
    issues_json="$(vast_append_issue "$issues_json" \
      "Elevated ${kind^} Capacity for VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
      "${kind^} capacity utilization is ${pct}% (warning threshold ${CAPACITY_THRESHOLD}%)." \
      "3" \
      "Plan capacity expansion and review snapshot/retention policies")"
  fi
done

echo "$issues_json" > "$OUTPUT_FILE"
echo -e "$report" > "$REPORT_FILE"
echo -e "$report"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
