#!/usr/bin/env bash
set -euo pipefail
# Projects capacity headroom from topology/metrics and optional snapshot delta.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="capacity_projection_issues.json"
PROJECTION_SNAPSHOT_FILE="${PROJECTION_SNAPSHOT_FILE:-seaweedfs_capacity_projection_snapshot.json}"
CAPACITY_WARN_PERCENT="${CAPACITY_WARN_PERCENT:-80}"
MIN_PROJECTION_HOURS="${MIN_PROJECTION_HOURS:-24}"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  echo "=== SeaweedFS capacity projection ==="
  [[ -f "$PROJECTION_SNAPSHOT_FILE" ]] && jq '.' "$PROJECTION_SNAPSHOT_FILE" 2>/dev/null || true
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

now_epoch=$(date +%s)
snapshot=$(jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson epoch "$now_epoch" '{timestamp: $ts, epoch: $epoch, slots: {}, disk: []}')

if dir_status=$(swf_master_http "/dir/status" 2>/dev/null); then
  free=$(echo "$dir_status" | jq -r '.Topology.Free // .topology.free // empty')
  max=$(echo "$dir_status" | jq -r '.Topology.Max // .topology.max // empty')
  if [[ "$free" =~ ^[0-9]+$ ]] && [[ "$max" =~ ^[0-9]+$ ]] && [[ "$max" -gt 0 ]]; then
    used=$((max - free))
    util_pct=$(awk "BEGIN {printf \"%.1f\", ($used / $max) * 100}")
    snapshot=$(echo "$snapshot" | jq --argjson free "$free" --argjson max "$max" --arg util "$util_pct" \
      '.slots = {free: $free, max: $max, used: ($max - $free), utilization_percent: ($util | tonumber)}')

    if awk "BEGIN {exit !($util_pct >= $CAPACITY_WARN_PERCENT)}"; then
      swf_add_issue \
        "SeaweedFS volume slot utilization at ${util_pct}% in \`${NAMESPACE}\`" \
        "Topology Free=${free}, Max=${max}, warn threshold=${CAPACITY_WARN_PERCENT}%" \
        2 \
        "Plan volume server scale-out before Free slots reach zero."
    fi
  fi
fi

master_pod=$(swf_find_pod "master")
if [[ -n "$master_pod" ]] && master_metrics=$(swf_fetch_pod_metrics "$master_pod" "$METRICS_PORT" 2>/dev/null); then
  writable_sum=$(swf_metric_sum_matching "$master_metrics" "^SeaweedFS_master_volume_layout_writable")
  crowded_sum=$(swf_metric_sum_matching "$master_metrics" "^SeaweedFS_master_volume_layout_crowded")
  snapshot=$(echo "$snapshot" | jq \
    --argjson writable "${writable_sum:-0}" \
    --argjson crowded "${crowded_sum:-0}" \
    '.master_metrics = {writable_volumes: $writable, crowded_layouts: $crowded}')
  if [[ "${crowded_sum:-0}" =~ ^[0-9]+$ ]] && [[ "${crowded_sum:-0}" -gt 0 ]]; then
    swf_add_issue \
      "SeaweedFS crowded layouts may exhaust write headroom soon in \`${NAMESPACE}\`" \
      "Sum of crowded layout gauges=${crowded_sum}" \
      3 \
      "Add writable volumes or rebalance collections before writes fail."
  fi
fi

while IFS= read -r pod; do
  [[ -z "$pod" ]] && continue
  if status_json=$(swf_volume_http "$pod" "/status" 2>/dev/null); then
    vol_count=$(echo "$status_json" | jq '.Volumes // [] | length')
    ro_count=$(echo "$status_json" | jq '[.Volumes[]? | select(.readOnly == true or .ReadOnly == true)] | length')
    disk_line=$(echo "$status_json" | jq -r '.DiskUsages[]? | "\(.dir // .Dir // "data") \(.percent_free // .PercentFree // 100)"' 2>/dev/null | head -1)
    pct_free=$(echo "$disk_line" | awk '{print $2}')
    disk_util="0"
    if [[ -n "$pct_free" ]] && [[ "$pct_free" =~ ^[0-9.]+$ ]]; then
      disk_util=$(awk "BEGIN {printf \"%.1f\", 100 - $pct_free}")
    fi
    entry=$(jq -n \
      --arg pod "$pod" \
      --argjson volumes "${vol_count:-0}" \
      --argjson read_only "${ro_count:-0}" \
      --arg util "$disk_util" \
      '{pod: $pod, volume_count: $volumes, read_only_volumes: $read_only, disk_utilization_percent: ($util | tonumber)}')
    snapshot=$(echo "$snapshot" | jq --argjson e "$entry" '.disk += [$e]')

    if [[ "$disk_util" != "0" ]] && awk "BEGIN {exit !($disk_util >= $CAPACITY_WARN_PERCENT)}"; then
      swf_add_issue \
        "Volume server \`${pod}\` disk utilization projected high (${disk_util}%)" \
        "volume_count=${vol_count}, read_only=${ro_count}" \
        2 \
        "Expand PVC/storage class or add volume nodes before disk fills."
    fi
  fi
done < <("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" \
  -l "$(swf_label_selector volume)" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

prior_path=$(swf_capacity_snapshot_path)
if [[ -f "$prior_path" ]]; then
  prior_epoch=$(jq -r '.epoch // 0' "$prior_path" 2>/dev/null || echo 0)
  prior_used=$(jq -r '.slots.used // empty' "$prior_path" 2>/dev/null || true)
  cur_used=$(echo "$snapshot" | jq -r '.slots.used // empty')
  elapsed_hours=$(awk "BEGIN {printf \"%.2f\", ($now_epoch - $prior_epoch) / 3600}")
  if [[ "$prior_used" =~ ^[0-9]+$ ]] && [[ "$cur_used" =~ ^[0-9]+$ ]] && [[ "$prior_epoch" =~ ^[0-9]+$ ]] \
    && awk "BEGIN {exit !($elapsed_hours >= 1)}"; then
    delta=$((cur_used - prior_used))
    if [[ "$delta" -gt 0 ]]; then
      max_slots=$(echo "$snapshot" | jq -r '.slots.max // empty')
      rate_per_hour=$(awk "BEGIN {printf \"%.2f\", $delta / $elapsed_hours}")
      if [[ "$max_slots" =~ ^[0-9]+$ ]] && [[ "$max_slots" -gt "$cur_used" ]]; then
        remaining=$((max_slots - cur_used))
        hours_left=$(awk "BEGIN {printf \"%.1f\", $remaining / $rate_per_hour}")
        snapshot=$(echo "$snapshot" | jq \
          --argjson delta "$delta" \
          --arg rate "$rate_per_hour" \
          --arg hours "$hours_left" \
          --arg elapsed "$elapsed_hours" \
          '.projection = {slots_consumed_since_prior: $delta, hours_since_prior: ($elapsed | tonumber), slots_per_hour: ($rate | tonumber), estimated_hours_until_full: ($hours | tonumber)}')
        if awk "BEGIN {exit !($hours_left < $MIN_PROJECTION_HOURS)}"; then
          swf_add_issue \
            "SeaweedFS volume slots may exhaust within ${hours_left}h at current growth rate" \
            "Consumed ${delta} slots in ${elapsed_hours}h (~${rate_per_hour}/h); ${remaining} slots remain." \
            2 \
            "Scale volume servers or increase max volumes before slot exhaustion."
        fi
      fi
    fi
  fi
fi

echo "$snapshot" >"$PROJECTION_SNAPSHOT_FILE"
mkdir -p "$(dirname "$prior_path")" 2>/dev/null || true
echo "$snapshot" >"$prior_path"
swf_write_issues "$OUTPUT_FILE"
