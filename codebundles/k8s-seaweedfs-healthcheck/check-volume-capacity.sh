#!/usr/bin/env bash
set -euo pipefail
set -x
# Inspects volume server disk usage and read-only volume signals.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="volume_capacity_issues.json"
MIN_FREE_PCT="${MIN_FREE_DISK_PERCENT:-10}"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  { set +x; } 2>/dev/null || true
  echo "=== SeaweedFS volume server capacity ==="
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

volume_pods=$("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" -o json 2>/dev/null \
  | jq -r '.items[] | select(.status.phase=="Running") | select(
      (.metadata.labels["app.kubernetes.io/component"]? == "volume") or
      (.metadata.name | test("volume"; "i"))
    ) | .metadata.name' || true)

if [[ -z "$volume_pods" ]]; then
  swf_add_issue \
    "No running SeaweedFS volume server pods in namespace \`${NAMESPACE}\`" \
    "Volume capacity cannot be assessed without volume servers." \
    3 \
    "Enable volume servers in Helm chart and verify pods are Running."
  swf_write_issues "$OUTPUT_FILE"
  exit 0
fi

while IFS= read -r pod; do
  [[ -z "$pod" ]] && continue
  status_json=""
  if ! status_json=$(swf_volume_http "$pod" "/status" 2>/dev/null); then
    swf_add_issue \
      "Volume server \`${pod}\` /status unreachable in \`${NAMESPACE}\`" \
      "HTTP probe on port ${VOLUME_PORT} failed." \
      3 \
      "kubectl logs ${pod} -n ${NAMESPACE} --context ${CONTEXT}"
    continue
  fi

  disk_usage=$(echo "$status_json" | jq -r '.DiskUsages[]? | "\(.dir // .Dir // "unknown") free=\(.free // .Free // "?") percent_free=\(.percent_free // .PercentFree // "?")"' 2>/dev/null || true)
  if [[ -n "$disk_usage" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      pct=$(echo "$line" | sed -n 's/.*percent_free=\([0-9.]*\).*/\1/p')
      dir=$(echo "$line" | sed -n 's/^\([^ ]*\).*/\1/p')
      if [[ -n "$pct" ]] && awk "BEGIN {exit !($pct < $MIN_FREE_PCT)}"; then
        swf_add_issue \
          "Volume server \`${pod}\` disk free below ${MIN_FREE_PCT}% on \`${dir}\`" \
          "$line" \
          2 \
          "Free disk space on volume node or adjust minFreeSpacePercent in Helm values."
      fi
    done <<< "$disk_usage"
  fi

  read_only_count=$(echo "$status_json" | jq '[.Volumes[]? | select(.readOnly == true or .ReadOnly == true)] | length' 2>/dev/null || echo 0)
  if [[ "$read_only_count" =~ ^[0-9]+$ ]] && [[ "$read_only_count" -gt 0 ]]; then
    swf_add_issue \
      "Volume server \`${pod}\` reports ${read_only_count} read-only volume(s)" \
      "Read-only volumes often indicate disk pressure or manual marks." \
      2 \
      "Inspect /status on ${pod} and master topology for readOnly volumes."
  fi
done <<< "$volume_pods"

# Master topology may also expose aggregate disk signals
if dir_status=$(swf_master_http "/dir/status" 2>/dev/null); then
  low_nodes=$(echo "$dir_status" | jq '[.. | objects | select(has("Max") and has("Free")) | select(.Max > 0 and (.Free / .Max * 100) < '"$MIN_FREE_PCT"')] | length' 2>/dev/null || echo 0)
  if [[ "$low_nodes" =~ ^[0-9]+$ ]] && [[ "$low_nodes" -gt 0 ]]; then
    swf_add_issue \
      "SeaweedFS topology reports ${low_nodes} node(s) with low free slot ratio in \`${NAMESPACE}\`" \
      "Derived from /dir/status Free/Max ratios below ${MIN_FREE_PCT}%." \
      3 \
      "Add capacity or retire full volume nodes."
  fi
fi

swf_write_issues "$OUTPUT_FILE"
