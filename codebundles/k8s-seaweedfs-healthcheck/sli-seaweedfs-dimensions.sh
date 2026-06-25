#!/usr/bin/env bash
set -euo pipefail
# Lightweight SLI dimension probe; prints JSON to stdout.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

# shellcheck disable=SC1091
source seaweedfs-lib.sh

score_workload=1
score_master=1
score_slots=1
score_connectivity=1

map_json=$(swf_discover_components)
bad_workloads=$(echo "$map_json" | jq '[.statefulsets[], .deployments[] | select(.replicas > 0 and .ready < .replicas)] | length')
if [[ "$bad_workloads" -gt 0 ]]; then
  score_workload=0
fi

if health=$(swf_master_http "/cluster/healthz" 2>/dev/null); then
  if ! echo "$health" | grep -qiE 'ok|healthy|success'; then
    score_master=0
  fi
else
  score_master=0
fi

min_free="${MIN_FREE_VOLUME_SLOTS:-1}"
if dir_status=$(swf_master_http "/dir/status" 2>/dev/null); then
  free=$(echo "$dir_status" | jq -r '.Topology.Free // .topology.free // 999' 2>/dev/null || echo 999)
  if [[ "$free" =~ ^[0-9]+$ ]] && [[ "$free" -lt "$min_free" ]]; then
    score_slots=0
  fi
else
  score_slots=0
fi

filer_pod=$(swf_find_pod "filer")
if [[ -z "$filer_pod" ]]; then
  score_connectivity=0
else
  if ! swf_filer_http "/healthz" >/dev/null 2>&1 && ! swf_filer_http "/status" >/dev/null 2>&1; then
    score_connectivity=0
  fi
fi

jq -n \
  --argjson workload "$score_workload" \
  --argjson master "$score_master" \
  --argjson slots "$score_slots" \
  --argjson connectivity "$score_connectivity" \
  '{workload: $workload, master: $master, slots: $slots, connectivity: $connectivity}'
