#!/usr/bin/env bash
set -euo pipefail
set -x
# Parses /dir/status topology for free volume slots.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="volume_slots_issues.json"
MIN_FREE="${MIN_FREE_VOLUME_SLOTS:-1}"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  { set +x; } 2>/dev/null || true
  echo "=== SeaweedFS volume slot topology ==="
  [[ -f dir_status_snapshot.json ]] && jq '{Free: .Topology.Free, Max: .Topology.Max, DataCenters: (.Topology.DataCenters // {} | keys)}' dir_status_snapshot.json 2>/dev/null || true
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

if ! dir_status=$(swf_master_http "/dir/status" 2>/dev/null); then
  swf_add_issue \
    "Unable to query SeaweedFS /dir/status in namespace \`${NAMESPACE}\`" \
    "Master topology API was unreachable." \
    2 \
    "Ensure master pod is Ready and HTTP is enabled (master.disableHttp=false)."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

echo "$dir_status" >dir_status_snapshot.json

root_free=$(echo "$dir_status" | jq -r '.Topology.Free // .topology.free // empty' 2>/dev/null || true)
root_max=$(echo "$dir_status" | jq -r '.Topology.Max // .topology.max // empty' 2>/dev/null || true)

if [[ -n "$root_free" && "$root_free" =~ ^[0-9]+$ ]]; then
  if [[ "$root_free" -lt "$MIN_FREE" ]]; then
    swf_add_issue \
      "SeaweedFS cluster free volume slots below threshold in \`${NAMESPACE}\`" \
      "Topology Free=${root_free}, Max=${root_max:-unknown}, required minimum=${MIN_FREE}" \
      2 \
      "Add volume servers or increase max volumes per node in Helm values."
  fi
else
  swf_add_issue \
    "SeaweedFS /dir/status missing Topology.Free in namespace \`${NAMESPACE}\`" \
    "Could not parse free slot count from master response." \
    3 \
    "Verify SeaweedFS version compatibility; inspect raw /dir/status output."
fi

# Walk nested topology nodes for local exhaustion
while IFS= read -r node; do
  [[ -z "$node" ]] && continue
  path=$(echo "$node" | jq -r '.path')
  free=$(echo "$node" | jq -r '.free')
  max=$(echo "$node" | jq -r '.max')
  if [[ "$free" =~ ^[0-9]+$ ]] && [[ "$free" -lt "$MIN_FREE" ]]; then
    swf_add_issue \
      "Low free volume slots at topology node \`${path}\` in \`${NAMESPACE}\`" \
      "Free=${free}, Max=${max}" \
      3 \
      "Scale volume servers in rack/datacenter ${path} or rebalance volumes."
  fi
done < <(echo "$dir_status" | jq -c '
  def walk_nodes(obj; path):
    (obj // {}) | to_entries[] |
    . as $e |
    (path + "/" + $e.key) as $p |
    ($e.value | if (.Free? != null) or (.free? != null) then
      {path: $p, free: ($e.value.Free // $e.value.free // 0), max: ($e.value.Max // $e.value.max // 0)}
    else empty end),
    (if ($e.value | type) == "object" then walk_nodes($e.value; $p) else empty end);
  .Topology // .topology // {} |
  walk_nodes(.DataCenters // .dataCenters // {}; "root")
')

swf_write_issues "$OUTPUT_FILE"
