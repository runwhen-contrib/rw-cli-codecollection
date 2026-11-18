#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/atlas-api-common.inc.sh"

OUTPUT_FILE="sli_mongodb_atlas_scores.json"

: "${ATLAS_PROJECT_ID:?Must set ATLAS_PROJECT_ID}"

CLUSTER_FILTER="${CLUSTER_FILTER:-}"
SLI_MAX_MEASUREMENT_PROCESSES="${SLI_MAX_MEASUREMENT_PROCESSES:-8}"
METRIC_WINDOW='granularity=PT5M&period=PT45M&m=CONNECTIONS_PERCENT&m=NORMALIZED_SYSTEM_CPU_USER'

api_ok=0
idle_ok=0
metrics_ok=0

payload_out() {
  jq -nc \
    --argjson api "$api_ok" \
    --argjson idle "$idle_ok" \
    --argjson met "$metrics_ok" \
    '{api_ok:$api, clusters_stable:$idle, metrics_snapshot_ok:$met}'
}

if ! atlas_resolve_credentials; then
  api_ok=0
  idle_ok=0
  metrics_ok=0
  payload_out | tee "$OUTPUT_FILE"
  exit 0
fi

atlas_clusters_json "${ATLAS_PROJECT_ID}"
if [[ "${atlas_last_http_status:-}" != "200" ]]; then
  api_ok=0
else
  api_ok=1
fi

if [[ "${api_ok}" != "1" ]]; then
  idle_ok=0
  metrics_ok=0
  payload_out | tee "$OUTPUT_FILE"
  exit 0
fi

clusters_payload="${atlas_last_http_body}"
filtered="$(filter_clusters_by_name "${clusters_payload}" "${CLUSTER_FILTER}")"
count="$(echo "$filtered" | jq 'length')"
if [[ "$count" == "0" ]]; then
  idle_ok=1
  metrics_ok=1
  payload_out | tee "$OUTPUT_FILE"
  exit 0
fi

bad_idle=0
while IFS= read -r cjson; do
  [[ -z "$cjson" ]] && continue
  paused="$(echo "$cjson" | jq -r '.paused // false')"
  state="$(echo "$cjson" | jq -r '.stateName // (.state.name // empty)')"
  [[ -z "$state" ]] && state="IDLE"
  sidle="${state^^}"
  if [[ "$paused" == "true" ]] || [[ "$sidle" != "IDLE" && "$sidle" != "MONGOS_ONLY" ]]; then
    bad_idle=1
  fi
done < <(echo "$filtered" | jq -c '.[]')

if [[ "$bad_idle" == "0" ]]; then
  idle_ok=1
fi

metrics_ok=1

atlas_processes_json "${ATLAS_PROJECT_ID}"
if [[ "${atlas_last_http_status:-}" != "200" ]]; then
  metrics_ok=1
else
  proc_blob="${atlas_last_http_body}"
  measured=0
  while IFS= read -r cjson; do
    [[ "${measured}" -ge "${SLI_MAX_MEASUREMENT_PROCESSES}" ]] && break
    [[ -z "$cjson" ]] && continue
    cname="$(echo "$cjson" | jq -r '.name')"
    pid="$(echo "$proc_blob" | jq -r --arg cn "$cname" '
      first(
        (.results // [])[]
        | select(.typeName == "REPLICA_PRIMARY")
        | select(.replicaSetName != null)
        | select(.replicaSetName == $cn or (.replicaSetName | startswith($cn + "-")))
        | .id
      ) // empty
    ')"
    [[ -z "$pid" ]] && continue
    atlas_measurement_json "${ATLAS_PROJECT_ID}" "${pid}" "?${METRIC_WINDOW}"
    measured=$((measured + 1))
    if [[ "${atlas_last_http_status:-}" != "200" ]]; then
      continue
    fi
    mbuf="${atlas_last_http_body}"
    conn="$(echo "$mbuf" | jq -r '
      [.measurements[]?
        | select(.name=="CONNECTIONS_PERCENT")
        | .dataPoints[]?
        | (.value | select(. != null))
      ] | max // empty
    ')"
    cpu="$(echo "$mbuf" | jq -r '
      [.measurements[]?
        | select(.name=="NORMALIZED_SYSTEM_CPU_USER")
        | .dataPoints[]?
        | (.value | select(. != null))
      ] | max // empty
    ')"
    ct="${CONNECTION_THRESHOLD:-85}"
    cpu_lim="${CPU_UTIL_THRESHOLD:-92}"
    if [[ -n "$conn" ]] && awk -v c="$ct" -v v="$conn" 'BEGIN { exit !( (v+0) > (c+0) ) }'; then
      metrics_ok=0
      break
    fi
    if [[ -n "$cpu" ]] && awk -v c="$cpu_lim" -v v="$cpu" 'BEGIN { exit !( (v+0) > (c+0) ) }'; then
      metrics_ok=0
      break
    fi
  done < <(echo "$filtered" | jq -c '.[]')
fi

payload_out | tee "$OUTPUT_FILE"
