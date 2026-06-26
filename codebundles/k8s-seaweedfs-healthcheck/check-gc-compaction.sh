#!/usr/bin/env bash
set -euo pipefail
# Surfaces garbage-collection, compaction, and delete-path error signals from SeaweedFS metrics.
: "${CONTEXT:?Must set CONTEXT}"
: "${NAMESPACE:?Must set NAMESPACE}"

OUTPUT_FILE="gc_compaction_issues.json"
GC_SNAPSHOT_FILE="${GC_SNAPSHOT_FILE:-seaweedfs_gc_snapshot.json}"
MAX_PICK_FOR_WRITE_ERRORS="${MAX_PICK_FOR_WRITE_ERRORS:-100}"
MAX_VOLUME_DISK_ERRORS="${MAX_VOLUME_DISK_ERRORS:-50}"
MAX_READONLY_NO_DELETE="${MAX_READONLY_NO_DELETE:-5}"
# shellcheck disable=SC1091
source seaweedfs-lib.sh

print_report() {
  echo "=== SeaweedFS GC / compaction signals ==="
  [[ -f "$GC_SNAPSHOT_FILE" ]] && jq '.' "$GC_SNAPSHOT_FILE" 2>/dev/null || true
  jq -r '.[] | "  - [sev=\(.severity)] \(.title)"' "$OUTPUT_FILE" 2>/dev/null || true
}
trap print_report EXIT

snapshot='{"master":{},"volumes":[],"filer":{}}'

master_pod=$(swf_find_pod "master")
if [[ -n "$master_pod" ]]; then
  if master_metrics=$(swf_fetch_pod_metrics "$master_pod" "$METRICS_PORT" 2>/dev/null); then
    pick_err=$(swf_metric_gauge_value "$master_metrics" "SeaweedFS_master_pick_for_write_error")
    crowded=$(swf_metric_sum_matching "$master_metrics" "^SeaweedFS_master_volume_layout_crowded")
    hb_err=$(echo "$master_metrics" | awk '/SeaweedFS_master_received_heartbeats\{type="error"\}/ {print $2; exit}' || echo 0)
    snapshot=$(echo "$snapshot" | jq \
      --argjson pick "${pick_err:-0}" \
      --argjson crowded "${crowded:-0}" \
      --argjson hb_err "${hb_err:-0}" \
      '.master = {pick_for_write_error: $pick, crowded_layouts: $crowded, heartbeat_errors: $hb_err}')

    if [[ "${pick_err:-0}" =~ ^[0-9]+$ ]] && [[ "${pick_err:-0}" -gt "$MAX_PICK_FOR_WRITE_ERRORS" ]]; then
      swf_add_issue \
        "SeaweedFS master pick-for-write errors elevated in \`${NAMESPACE}\`" \
        "SeaweedFS_master_pick_for_write_error=${pick_err} (threshold=${MAX_PICK_FOR_WRITE_ERRORS})" \
        2 \
        "Inspect writable layouts, read-only volumes, and slot availability; scale volume servers."
    fi
    if [[ "${crowded:-0}" =~ ^[0-9]+$ ]] && [[ "${crowded:-0}" -gt 0 ]]; then
      swf_add_issue \
        "SeaweedFS reports crowded volume layouts in \`${NAMESPACE}\`" \
        "SeaweedFS_master_volume_layout_crowded sum=${crowded}" \
        2 \
        "Run volume vacuum/balance if needed; add capacity or tune volumeSizeLimitMB."
    fi
    if [[ "${hb_err:-0}" =~ ^[0-9]+$ ]] && [[ "${hb_err:-0}" -gt 0 ]]; then
      swf_add_issue \
        "SeaweedFS master received volume heartbeat errors" \
        "SeaweedFS_master_received_heartbeats{type=\"error\"}=${hb_err}" \
        2 \
        "Check volume server logs and network paths to master port ${MASTER_PORT}."
    fi
  fi
fi

filer_pod=$(swf_find_pod "filer")
if [[ -n "$filer_pod" ]]; then
  if filer_metrics=$(swf_fetch_pod_metrics "$filer_pod" "$METRICS_PORT" 2>/dev/null); then
    delete_ops=$(swf_metric_sum_matching "$filer_metrics" 'SeaweedFS_filerStore_request_seconds_count.*type="delete"')
    snapshot=$(echo "$snapshot" | jq --argjson del "${delete_ops:-0}" '.filer = {delete_store_ops: $del}')
  fi
fi

while IFS= read -r pod; do
  [[ -z "$pod" ]] && continue
  vol_entry='{}'
  if vol_metrics=$(swf_fetch_pod_metrics "$pod" "$METRICS_PORT" 2>/dev/null); then
    disk_err=$(swf_metric_sum_matching "$vol_metrics" 'errorWriteToLocalDisk')
    size_err=$(swf_metric_sum_matching "$vol_metrics" 'errorSizeMismatchOffsetSize')
    ro_no_delete=$(swf_metric_sum_matching "$vol_metrics" 'noWriteOrDelete')
    ro_can_delete=$(swf_metric_sum_matching "$vol_metrics" 'noWriteCanDelete')
    vol_entry=$(jq -n \
      --arg pod "$pod" \
      --argjson disk_err "${disk_err:-0}" \
      --argjson size_err "${size_err:-0}" \
      --argjson ro_no_delete "${ro_no_delete:-0}" \
      --argjson ro_can_delete "${ro_can_delete:-0}" \
      '{pod: $pod, disk_write_errors: $disk_err, size_mismatch_errors: $size_err, read_only_no_delete: $ro_no_delete, read_only_can_delete: $ro_can_delete}')
    snapshot=$(echo "$snapshot" | jq --argjson v "$vol_entry" '.volumes += [$v]')

    if [[ "${disk_err:-0}" =~ ^[0-9]+$ ]] && [[ "${disk_err:-0}" -gt "$MAX_VOLUME_DISK_ERRORS" ]]; then
      swf_add_issue \
        "Volume server \`${pod}\` reports disk write errors (possible GC/compaction pressure)" \
        "SeaweedFS_volumeServer_handler_total{type=\"errorWriteToLocalDisk\"}=${disk_err}" \
        2 \
        "Check disk space, PVC capacity, and read-only volumes on ${pod}."
    fi
    if [[ "${ro_no_delete:-0}" =~ ^[0-9]+$ ]] && [[ "${ro_no_delete:-0}" -gt "$MAX_READONLY_NO_DELETE" ]]; then
      swf_add_issue \
        "Volume server \`${pod}\` has volumes in noWriteOrDelete state" \
        "read_only_noWriteOrDelete=${ro_no_delete} volumes may block deletes and GC." \
        2 \
        "Investigate collection TTL/vacuum settings and disk pressure on ${pod}."
    fi
  fi
done < <("${KUBECTL}" get pods -n "${NAMESPACE}" --context "${CONTEXT}" \
  -l "$(swf_label_selector volume)" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)

echo "$snapshot" >"$GC_SNAPSHOT_FILE"
swf_write_issues "$OUTPUT_FILE"
