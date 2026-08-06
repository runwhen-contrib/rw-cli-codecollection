#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# Verifies replication links, protection groups, and snapshot pressure signals.
# -----------------------------------------------------------------------------

OUTPUT_FILE="replication_status_output.json"
REPORT_FILE="replication_status_report.txt"

source "$(dirname "$0")/vast-vms-common.sh"

issues_json="$(vast_init_issues)"
report="Replication and protection status for \`${VAST_CLUSTER_NAME}\`\n"

if ! _vast_load_credentials; then
  issues_json="$(vast_api_error_issue "$issues_json" "credentials" "missing vast_vms_credentials")"
  echo "$issues_json" > "$OUTPUT_FILE"
  echo -e "$report" > "$REPORT_FILE"
  exit 0
fi

if clusters_json="$(vast_api_get "/api/clusters/" 2>clusters.err)"; then
  cluster_obj="$(vast_find_cluster_json "$clusters_json" "$VAST_CLUSTER_NAME")"
  if [[ -n "$cluster_obj" ]]; then
    repl_enabled="$(echo "$cluster_obj" | jq -r '.replication_enabled // .replication // empty')"
    aux_pct="$(echo "$cluster_obj" | jq -r '.auxiliary_space_in_use_percent // empty')"
    if [[ "$repl_enabled" == "false" ]]; then
      report+="Cluster replication_enabled=false (informational).\n"
    fi
    if [[ -n "$aux_pct" && "$aux_pct" != "null" ]]; then
      report+="Auxiliary/snapshot space in use: ${aux_pct}%\n"
      aux_cmp="$(python3 - <<PY
pct=float("${aux_pct}")
print("high" if pct >= float("${CRITICAL_CAPACITY_THRESHOLD}") else ("warn" if pct >= float("${CAPACITY_THRESHOLD}") else "ok"))
PY
)"
      if [[ "$aux_cmp" == "high" ]]; then
        issues_json="$(vast_append_issue "$issues_json" \
          "High Snapshot/Auxiliary Capacity on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
          "Auxiliary space (snapshots/replication metadata) is ${aux_pct}% of capacity." \
          "2" \
          "Review snapshot retention, protection policies, and replication backlog")"
      elif [[ "$aux_cmp" == "warn" ]]; then
        issues_json="$(vast_append_issue "$issues_json" \
          "Elevated Snapshot/Auxiliary Capacity on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
          "Auxiliary space is ${aux_pct}% (warning threshold ${CAPACITY_THRESHOLD}%)." \
          "3" \
          "Audit protection groups and snapshot schedules for capacity pressure")"
      fi
    fi
  fi
else
  err_msg="$(cat clusters.err 2>/dev/null || echo unknown)"
  issues_json="$(vast_api_error_issue "$issues_json" "replication status" "$err_msg")"
fi
rm -f clusters.err

if repl_text="$(vast_prometheus_get "replications" 2>repl.err)"; then
  unhealthy="$(echo "$repl_text" | awk '
    $0 !~ /^#/ && ($0 ~ /state|status|lag|behind|failed|error/ || $0 ~ /replication/) && ($0 ~ /0$/ || $0 ~ /failed|error|lag|behind|stalled/i) {
      print $0
    }
  ' | head -20)"
  if [[ -n "$unhealthy" ]]; then
    issues_json="$(vast_append_issue "$issues_json" \
      "Replication Stream Issues on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
      "Prometheus replications metrics indicate unhealthy streams:\n${unhealthy}" \
      "2" \
      "Verify replication peer connectivity, bandwidth limits, and protection group health in VMS")"
    report+="Unhealthy replication metric samples detected.\n"
  else
    report+="Replication Prometheus metrics show no obvious failures.\n"
  fi
else
  report+="Note: /api/prometheusmetrics/replications unavailable (requires VAST 5.2-sp10+).\n"
fi
rm -f repl.err

if pg_json="$(vast_api_get "/api/protectiongroups/" 2>pg.err)"; then
  bad_pg="$(echo "$pg_json" | jq -r '
    (if type == "array" then . elif .results then .results else [.] end)
    | map(select((.state // .status // "OK") | ascii_upcase | test("FAILED|ERROR|DEGRADED|OFFLINE")))
    | map("\(.name // .title // .id // "pg") state=\(.state // .status)")
    | .[]
  ' 2>/dev/null || true)"
  if [[ -n "$bad_pg" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      issues_json="$(vast_append_issue "$issues_json" \
        "Protection Group Issue on VAST Cluster \`${VAST_CLUSTER_NAME}\`" \
        "Protection group reports: ${line}" \
        "2" \
        "Review protection group configuration and replication targets in VMS")"
      report+="Protection group issue: ${line}\n"
    done <<< "$bad_pg"
  else
    report+="Protection groups REST check: no failed groups found.\n"
  fi
else
  report+="Note: /api/protectiongroups/ unavailable on this VAST version.\n"
fi
rm -f pg.err

echo "$issues_json" > "$OUTPUT_FILE"
echo -e "$report" > "$REPORT_FILE"
echo -e "$report"
echo "Analysis completed. Results saved to $OUTPUT_FILE"
