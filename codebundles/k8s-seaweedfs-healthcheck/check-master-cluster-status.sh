#!/usr/bin/env bash
set -euo pipefail
set -x
# Queries SeaweedFS master /cluster/status and /cluster/healthz.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="master_cluster_issues.json"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  { set +x; } 2>/dev/null || true
  echo "=== SeaweedFS master cluster status ==="
  [[ -f master_status_snapshot.json ]] && jq '.' master_status_snapshot.json || echo "(no snapshot)"
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

master_pod=$(swf_find_pod "master")
if [[ -z "$master_pod" ]]; then
  swf_add_issue \
    "No running SeaweedFS master pod found in namespace \`${NAMESPACE}\`" \
    "Cannot query /cluster/status without a master pod." \
    2 \
    "Verify master StatefulSet is running and labeled app.kubernetes.io/component=master."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

healthz=""
status_json=""
if ! healthz=$(swf_master_http "/cluster/healthz" 2>/dev/null); then
  swf_add_issue \
    "SeaweedFS master /cluster/healthz unreachable in namespace \`${NAMESPACE}\`" \
    "HTTP probe to master API failed from pod ${master_pod}." \
    2 \
    "Port-forward or exec into ${master_pod} and curl http://127.0.0.1:${MASTER_PORT}/cluster/healthz"
fi

if ! status_json=$(swf_master_http "/cluster/status" 2>/dev/null); then
  swf_add_issue \
    "SeaweedFS master /cluster/status unreachable in namespace \`${NAMESPACE}\`" \
    "Could not retrieve Raft cluster status from master." \
    2 \
    "Check master logs and network policies blocking in-cluster HTTP on port ${MASTER_PORT}."
else
  echo "$status_json" >master_status_snapshot.json
fi

if [[ -n "$healthz" ]]; then
  if ! echo "$healthz" | grep -qiE 'ok|healthy|success'; then
    swf_add_issue \
      "SeaweedFS master health check returned unhealthy response in \`${NAMESPACE}\`" \
      "Response: ${healthz}" \
      2 \
      "Investigate master Raft peers and restart stuck master pods if leadership is lost."
  fi
fi

if [[ -n "$status_json" ]]; then
  leader=$(echo "$status_json" | jq -r '.Leader // .leader // empty' 2>/dev/null || true)
  is_leader=$(echo "$status_json" | jq -r '.IsLeader // .isLeader // empty' 2>/dev/null || true)
  peers=$(echo "$status_json" | jq -r '(.Peers // .peers // []) | length' 2>/dev/null || echo 0)

  if [[ -z "$leader" && "$is_leader" != "true" && "$is_leader" != "True" ]]; then
    swf_add_issue \
      "SeaweedFS master cluster has no elected leader in namespace \`${NAMESPACE}\`" \
      "cluster/status did not report Leader or IsLeader=true. peers=${peers}" \
      2 \
      "Review master StatefulSet ordinals, persistent volumes, and Raft logs."
  fi

  if [[ "$peers" =~ ^[0-9]+$ ]] && [[ "$peers" -eq 0 ]]; then
    master_replicas=1
    map_json=$(swf_discover_components)
    master_replicas=$(echo "$map_json" | jq '[.statefulsets[] | select(.component == "master" or (.name | test("master"; "i")))] | .[0].replicas // 1')
    if [[ "$master_replicas" =~ ^[0-9]+$ ]] && [[ "$master_replicas" -gt 1 ]]; then
      swf_add_issue \
        "SeaweedFS master reports zero Raft peers in namespace \`${NAMESPACE}\`" \
        "Peer membership may be incomplete for HA master setups." \
        3 \
        "Confirm master.replicas and cluster bootstrap settings in Helm values."
    fi
  fi
fi

swf_write_issues "$OUTPUT_FILE"
