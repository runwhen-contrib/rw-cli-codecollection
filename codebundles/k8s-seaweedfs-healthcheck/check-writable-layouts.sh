#!/usr/bin/env bash
set -euo pipefail
set -x
# Evaluates writable volume layouts from /dir/status.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="writable_layouts_issues.json"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  { set +x; } 2>/dev/null || true
  echo "=== SeaweedFS writable layouts ==="
  [[ -f writable_layouts_snapshot.json ]] && jq '.' writable_layouts_snapshot.json 2>/dev/null || true
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

if ! dir_status=$(swf_master_http "/dir/status" 2>/dev/null); then
  swf_add_issue \
    "Unable to evaluate writable layouts: /dir/status unreachable in \`${NAMESPACE}\`" \
    "Master API call failed." \
    2 \
    "Restore master HTTP access before checking writable layouts."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

layouts=$(echo "$dir_status" | jq -c '
  [
    (.Layouts // .layouts // {} | to_entries[] | {name: .key, writable: (.value.writables // .value.Writables // [] | length), replication: (.value.replication // .value.Replication // "unknown")}),
    (.Topology.Layouts // .topology.layouts // {} | to_entries[]? | {name: .key, writable: (.value.writables // .value.Writables // [] | length), replication: (.value.replication // .value.Replication // "unknown")})
  ] | map(select(.name != null))
' 2>/dev/null || echo '[]')

echo "$layouts" >writable_layouts_snapshot.json

layout_count=$(echo "$layouts" | jq 'length')
if [[ "$layout_count" -eq 0 ]]; then
  # Fallback: inspect topology writables at root
  root_writables=$(echo "$dir_status" | jq -r '.Topology.Writables // .topology.writables // [] | length' 2>/dev/null || echo "")
  if [[ -n "$root_writables" && "$root_writables" =~ ^[0-9]+$ && "$root_writables" -eq 0 ]]; then
    swf_add_issue \
      "SeaweedFS topology root has zero writable volumes in \`${NAMESPACE}\`" \
      "/dir/status reported no writables at cluster root." \
      2 \
      "Verify volume servers are registered and not read-only; check defaultReplication settings."
  fi
else
  while IFS= read -r layout; do
    [[ -z "$layout" ]] && continue
    lname=$(echo "$layout" | jq -r '.name')
    writable=$(echo "$layout" | jq -r '.writable')
    repl=$(echo "$layout" | jq -r '.replication')
    if [[ "$writable" =~ ^[0-9]+$ ]] && [[ "$writable" -eq 0 ]]; then
      swf_add_issue \
        "SeaweedFS layout \`${lname}\` has zero writable volumes in \`${NAMESPACE}\`" \
        "replication=${repl}, writable count=0" \
        2 \
        "Ensure enough volume servers exist for replication ${repl}; check collection placement."
    fi
  done < <(echo "$layouts" | jq -c '.[]')
fi

# Read-only volumes in layouts
readonly_vols=$(echo "$dir_status" | jq '[.. | objects | .readOnlyVolumeIds? // .ReadOnlyVolumeIds? // empty | .[]? ] | length' 2>/dev/null || echo 0)
if [[ "$readonly_vols" =~ ^[0-9]+$ ]] && [[ "$readonly_vols" -gt 0 ]]; then
  swf_add_issue \
    "SeaweedFS reports ${readonly_vols} read-only volume id(s) in layouts for \`${NAMESPACE}\`" \
    "Read-only volumes block writes for affected collections." \
    2 \
    "Investigate disk space on hosting volume servers and clear readOnly flags when safe."
fi

swf_write_issues "$OUTPUT_FILE"
