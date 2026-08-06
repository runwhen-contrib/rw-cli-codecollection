#!/usr/bin/env bash
set -euo pipefail
# Lightweight SLI scoring script — outputs JSON with binary sub-scores.

source "$(dirname "$0")/vast-vms-common.sh"

if ! _vast_load_credentials; then
  jq -n '{
    vms_clustered: 0,
    capacity_ok: 0,
    nodes_healthy: 0,
    alarms_clear: 0,
    replication_ok: 1,
    details: {error: "missing credentials"}
  }'
  exit 0
fi

vms_clustered=0
capacity_ok=1
nodes_healthy=1
alarms_clear=1
replication_ok=1
details='{}'

if vms_state_text="$(vast_prometheus_get "vms_state" 2>/dev/null)"; then
  vms_state="$(vast_prometheus_gauge "$vms_state_text" "vms_state")"
  [[ -z "$vms_state" ]] && vms_state="$(vast_prometheus_gauge "$vms_state_text" "vast_vms_state")"
  [[ "$vms_state" == "1" ]] && vms_clustered=1
  details="$(jq -n --arg s "${vms_state:-unknown}" '{vms_state: $s}')"
else
  if clusters_json="$(vast_api_get "/api/clusters/" 2>/dev/null)"; then
    cluster_obj="$(vast_find_cluster_json "$clusters_json" "$VAST_CLUSTER_NAME")"
    state="$(echo "$cluster_obj" | jq -r '.state // "UNKNOWN"')"
    [[ "$state" == "ONLINE" || "$state" == "CLUSTERED" ]] && vms_clustered=1
    details="$(jq -n --arg s "$state" '{cluster_state: $s}')"
  fi
fi

if clusters_json="$(vast_api_get "/api/clusters/" 2>/dev/null)"; then
  cluster_obj="$(vast_find_cluster_json "$clusters_json" "$VAST_CLUSTER_NAME")"
  if [[ -n "$cluster_obj" ]]; then
    for pct_field in physical_space_in_use_percent logical_space_in_use_percent; do
      pct="$(echo "$cluster_obj" | jq -r --arg f "$pct_field" '.[$f] // empty')"
      [[ -z "$pct" || "$pct" == "null" ]] && continue
      ok="$(python3 - <<PY
print(1 if float("${pct}") < float("${CAPACITY_THRESHOLD}") else 0)
PY
)"
      [[ "$ok" == "0" ]] && capacity_ok=0
    done
  fi
fi

for path in "/api/cnodes/" "/api/dnodes/"; do
  if nodes_json="$(vast_api_get "$path" 2>/dev/null)"; then
    bad="$(echo "$nodes_json" | jq '
      (if type == "array" then . elif .results then .results else [.] end)
      | map(select((.state // .status // "ACTIVE") | ascii_upcase | test("OFFLINE|FAILED|INACTIVE|DISABLED|ERROR")))
      | length
    ' 2>/dev/null || echo 0)"
    [[ "$bad" -gt 0 ]] && nodes_healthy=0
  fi
done

if alarms_text="$(vast_prometheus_get "alarms" 2>/dev/null)"; then
  alarm_lines="$(echo "$alarms_text" | awk '$0 !~ /^#/ && $2 != "0" && $2 != "0.0" {c++} END {print c+0}')"
  [[ "$alarm_lines" -gt 0 ]] && alarms_clear=0
fi

if repl_text="$(vast_prometheus_get "replications" 2>/dev/null)"; then
  bad="$(echo "$repl_text" | awk '$0 !~ /^#/ && ($0 ~ /failed|error|stalled/i) {c++} END {print c+0}')"
  [[ "$bad" -gt 0 ]] && replication_ok=0
fi

jq -n \
  --argjson vms_clustered "$vms_clustered" \
  --argjson capacity_ok "$capacity_ok" \
  --argjson nodes_healthy "$nodes_healthy" \
  --argjson alarms_clear "$alarms_clear" \
  --argjson replication_ok "$replication_ok" \
  --argjson details "$details" \
  '{
    vms_clustered: $vms_clustered,
    capacity_ok: $capacity_ok,
    nodes_healthy: $nodes_healthy,
    alarms_clear: $alarms_clear,
    replication_ok: $replication_ok,
    details: $details
  }'
