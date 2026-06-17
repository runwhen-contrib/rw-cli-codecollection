#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/atlas-api-common.inc.sh"

OUTPUT_FILE="atlas_cluster_metrics_issues.json"
: "${ATLAS_PROJECT_ID:?Must set ATLAS_PROJECT_ID}"

CLUSTER_FILTER="${CLUSTER_FILTER:-}"
CONNECTION_THRESHOLD="${CONNECTION_THRESHOLD:-85}"
DISK_UTIL_THRESHOLD="${DISK_UTIL_THRESHOLD:-85}"
REPLICATION_LAG_MS_THRESHOLD="${REPLICATION_LAG_MS_THRESHOLD:-5000}"
CPU_UTIL_THRESHOLD="${CPU_UTIL_THRESHOLD:-92}"

issues_json='[]'

if ! atlas_resolve_credentials; then
  issues_json="$(append_issue_json "$issues_json" \
    "MongoDB Atlas metrics analysis blocked — credentials missing" \
    "Unable to authenticate to Atlas measurement endpoints." \
    4 \
    "Provide atlas_api_key_credentials with Project Read Only access.")"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

atlas_clusters_json "${ATLAS_PROJECT_ID}"
if [[ "${atlas_last_http_status:-}" != "200" ]]; then
  issues_json="$(append_issue_json "$issues_json" \
    "MongoDB Atlas cluster enumeration failed prior to metrics" \
    "$(echo "${atlas_last_http_body:-}" | jq -c . 2>/dev/null || true)" \
    4 \
    "Fix ATLAS_PROJECT_ID or API privileges, then rerun metrics.")"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

clusters_body="${atlas_last_http_body}"

atlas_processes_json "${ATLAS_PROJECT_ID}"
if [[ "${atlas_last_http_status:-}" != "200" ]]; then
  issues_json="$(append_issue_json "$issues_json" \
    "MongoDB Atlas process enumeration failed prior to measurements" \
    "$(echo "${atlas_last_http_body:-}" | jq -c . 2>/dev/null || true)" \
    3 \
    "Measurements require process inventory; verify Project Read Only access.")"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

processes_body="${atlas_last_http_body}"

PRIMARY_METRICS='granularity=PT5M&period=PT45M&m=CONNECTIONS_PERCENT&m=NORMALIZED_SYSTEM_CPU_USER&m=OPLOG_SLAVE_LAG_MASTER_TIME&m=DISK_PARTITION_SPACE_USED_DATA'
FALLBACK_METRICS='granularity=PT5M&period=PT45M&m=CONNECTIONS&m=NORMALIZED_SYSTEM_CPU_USER&m=DISK_PARTITION_SPACE_USED_DATA'

fetch_measurement_payload() {
  local raw_pid="$1"
  atlas_measurement_json "${ATLAS_PROJECT_ID}" "${raw_pid}" "?${PRIMARY_METRICS}"
  if [[ "${atlas_last_http_status:-}" != "200" ]]; then
    atlas_measurement_json "${ATLAS_PROJECT_ID}" "${raw_pid}" "?${FALLBACK_METRICS}"
  fi
}

max_metric_series() {
  local json_blob="$1"
  local mn="$2"
  echo "$json_blob" | jq -r --arg n "$mn" '
    [.measurements[]?
      | select(.name == $n)
      | .dataPoints[]?
      | select(.value != null)
      | .value
    ] | max // empty
  '
}

printf '📊 Atlas metrics — project=%s | conn_thresh%%=%s disk_thresh%%=%s lag_ms_thresh=%s cpu_warn%%=%s\n' \
  "$ATLAS_PROJECT_ID" "$CONNECTION_THRESHOLD" "$DISK_UTIL_THRESHOLD" "$REPLICATION_LAG_MS_THRESHOLD" "$CPU_UTIL_THRESHOLD"

filtered="$(filter_clusters_by_name "$clusters_body" "$CLUSTER_FILTER")"

while IFS= read -r cjson; do
  [[ -z "$cjson" ]] && continue
  cname="$(echo "$cjson" | jq -r '.name')"
  disk_gb="$(echo "$cjson" | jq -r '(try .diskSizeGB catch null) // empty')"
  if [[ -z "$disk_gb" || "$disk_gb" == "null" ]]; then disk_gb="0"; fi

  pmap="$(printf '%s\n' "${processes_body}" | jq -c --arg cn "$cname" '
    [(.results // [])[]
      | select(.replicaSetName != null)
      | select(.replicaSetName == $cn or (.replicaSetName | startswith($cn + "-")))
    ]
    | unique_by(.id)
  ')"

  nproc="$(echo "$pmap" | jq 'length')"
  if [[ "$nproc" == "0" ]]; then
    issues_json="$(append_issue_json "$issues_json" \
      "No scoped MongoDB processes for metrics on cluster \`${cname}\`" \
      "Atlas process inventory did not expose replica-set members labeled for \`${cname}\`; some flex/serverless tiers may omit these entries." \
      1 \
      "Validate cluster type supports host metrics APIs and consult Atlas Charts as a fallback.")"
    continue
  fi

  agg_conn="" agg_conn_raw="" agg_cpu="" agg_lag="" agg_disk=""

  while IFS= read -r rawpid; do
    [[ -z "$rawpid" ]] && continue
    fetch_measurement_payload "${rawpid}"
    mh="${atlas_last_http_status:-}"
    mbuf="${atlas_last_http_body:-}"
    if [[ "$mh" != "200" ]]; then
      continue
    fi
    pct="$(max_metric_series "$mbuf" "CONNECTIONS_PERCENT")"
    raw="$(max_metric_series "$mbuf" "CONNECTIONS")"
    cpu="$(max_metric_series "$mbuf" "NORMALIZED_SYSTEM_CPU_USER")"
    lag="$(max_metric_series "$mbuf" "OPLOG_SLAVE_LAG_MASTER_TIME")"
    disk="$(max_metric_series "$mbuf" "DISK_PARTITION_SPACE_USED_DATA")"

    if [[ -n "$pct" ]] && awk -v b="${agg_conn:-nan}" -v v="$pct" 'BEGIN{v=v+0; if (b=="nan" || b==""){exit 0}; b=b+0; exit !(v>b)}'; then agg_conn="$pct"; fi
    if [[ -n "$raw" ]] && awk -v b="${agg_conn_raw:-nan}" -v v="$raw" 'BEGIN{v=v+0; if (b=="nan" || b==""){exit 0}; b=b+0; exit !(v>b)}'; then agg_conn_raw="$raw"; fi

    if [[ -n "$cpu" ]] && awk -v b="${agg_cpu:-nan}" -v v="$cpu" 'BEGIN{v=v+0; if (b=="nan" || b==""){exit 0}; b=b+0; exit !(v>b)}'; then agg_cpu="$cpu"; fi
    if [[ -n "$lag" ]] && awk -v b="${agg_lag:-nan}" -v v="$lag" 'BEGIN{v=v+0; if (b=="nan" || b==""){exit 0}; b=b+0; exit !(v>b)}'; then agg_lag="$lag"; fi
    if [[ -n "$disk" ]] && awk -v b="${agg_disk:-nan}" -v v="$disk" 'BEGIN{v=v+0; if (b=="nan" || b==""){exit 0}; b=b+0; exit !(v>b)}'; then agg_disk="$disk"; fi
    sleep_int="${ATLAS_METRICS_MEASUREMENT_DELAY_MS:-200}"
    if [[ "${sleep_int}" =~ ^[0-9]+$ ]] && [[ "${sleep_int}" != "0" ]]; then
      ms_to_sec="$(awk -v ms="$sleep_int" 'BEGIN{printf("%.3f", ms/1000)}')"
      sleep "${ms_to_sec}"
    fi
  done < <(echo "$pmap" | jq -r '.[].id')

  conn_metric_label="CONNECTIONS_PERCENT"
  conn_metric_value="${agg_conn}"
  if [[ -z "${conn_metric_value:-}" ]]; then
    conn_metric_label="CONNECTIONS"
    conn_metric_value="${agg_conn_raw}"
  fi

  [[ -z "${conn_metric_value:-}" ]] || [[ "$conn_metric_value" == "null" ]] && conn_metric_value=""

  if [[ "${conn_metric_label}" == "CONNECTIONS_PERCENT" && -n "$conn_metric_value" ]]; then
    if awk -v c="${CONNECTION_THRESHOLD}" -v v="$conn_metric_value" 'BEGIN { exit !( (v+0) > (c+0) ) }'; then
      issues_json="$(append_issue_json "$issues_json" \
        "Elevated Atlas connection pressure for cluster \`${cname}\`" \
        "Peak ${conn_metric_label} observed across sampled processes ≈ ${conn_metric_value} (threshold=${CONNECTION_THRESHOLD})." \
        2 \
        "Review connection pools, orphaned clients, autoscaling tiers, IP access lists, or workload bursts.")"
    fi
  fi

  if [[ -n "${agg_cpu:-}" ]] && awk -v c="${CPU_UTIL_THRESHOLD}" -v v="$agg_cpu" 'BEGIN { exit !( (v+0) > (c+0) ) }'; then
    issues_json="$(append_issue_json "$issues_json" \
      "High normalized host CPU for Atlas cluster \`${cname}\`" \
      "Peak NORMALIZED_SYSTEM_CPU_USER sampled ≈ ${agg_cpu}% (configured CPU_UTIL_THRESHOLD=${CPU_UTIL_THRESHOLD}%)." \
      3 \
      "Tune query/index patterns, consider cluster scaling, investigate noisy neighbors on shared tiers.")"
  fi

  disk_pct=""
  if [[ "$disk_gb" != "0" ]] && [[ -n "${agg_disk:-}" ]]; then
    disk_pct="$(awk -v gb="$disk_gb" -v b="$agg_disk" 'BEGIN{if (gb+0<=0){print ""; exit}; printf("%.2f",(b+0)/(gb*1073741824)*100)}')"
  fi
  if [[ -n "${disk_pct}" ]] && awk -v d="${DISK_UTIL_THRESHOLD}" -v v="$disk_pct" 'BEGIN { exit !( (v+0) > (d+0) ) }'; then
    issues_json="$(append_issue_json "$issues_json" \
      "Elevated Atlas data disk utilization for cluster \`${cname}\`" \
      "Max DISK_PARTITION_SPACE_USED_DATA ≈ ${agg_disk} bytes vs provisioned diskSizeGB=${disk_gb} ⇒ ~${disk_pct}% (> ${DISK_UTIL_THRESHOLD}% threshold)." \
      2 \
      "Plan disk scale-out, archiving, or TTL/index cleanup; coordinate with Atlas online disk expansion.")"
  fi

  if [[ -n "${agg_lag:-}" ]] && awk -v l="${REPLICATION_LAG_MS_THRESHOLD}" -v v="$agg_lag" 'BEGIN { exit !( (v+0) > (l+0) ) }'; then
    issues_json="$(append_issue_json "$issues_json" \
      "Replication lag spike on Atlas cluster \`${cname}\`" \
      "Peak OPLOG_SLAVE_LAG_MASTER_TIME ≈ ${agg_lag}ms (>${REPLICATION_LAG_MS_THRESHOLD}ms)." \
      4 \
      "Inspect write load, replication windows, VPC latency, indexing operations, or investigate secondary eviction events.")"
  fi

  summary_line="$(printf '%s | %s_peak=%s %s_peak=%s%% disk_used_max=%sB disk_gb=%s repl_lag_peak_ms=%s' \
    "${cname}" "${conn_metric_label}" "${conn_metric_value:-na}" \
    "NORMALIZED_SYSTEM_CPU_USER" "${agg_cpu:-na}" "${agg_disk:-na}" "${disk_gb}" "${agg_lag:-na}")"
  printf '%s\n' "$summary_line"
done < <(echo "$filtered" | jq -c '.[]')

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
printf 'Atlas metrics sweep complete → %s\n' "$OUTPUT_FILE"
