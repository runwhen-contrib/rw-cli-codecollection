#!/usr/bin/env bash
set -euo pipefail
set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/atlas-api-common.inc.sh"

OUTPUT_FILE="atlas_cluster_state_issues.json"
: "${ATLAS_PROJECT_ID:?Must set ATLAS_PROJECT_ID}"

CLUSTER_FILTER="${CLUSTER_FILTER:-}"

issues_json='[]'

if ! atlas_resolve_credentials; then
  issues_json="$(append_issue_json "$issues_json" \
    "MongoDB Atlas API authentication failed — cluster state check skipped" \
    "Cannot resolve programmatic API credentials for digest auth." \
    4 \
    "Populate atlas_api_key_credentials with Atlas API public/private keys.")"
  echo "$issues_json" >"$OUTPUT_FILE"
  printf '%s\n' "credential resolution failed" >&2
  exit 0
fi

atlas_clusters_json "${ATLAS_PROJECT_ID}"
if [[ "${atlas_last_http_status:-}" != "200" ]]; then
  body="${atlas_last_http_body:-}"
  details="$(echo "$body" | jq -c . 2>/dev/null || printf '%s' "$body")"
  issues_json="$(append_issue_json "$issues_json" \
    "MongoDB Atlas cluster listing failed (\`${ATLAS_PROJECT_ID}\`)" \
    "HTTP ${atlas_last_http_status:-}: ${details}" \
    4 \
    "Fix API authorization or ATLAS_PROJECT_ID before evaluating cluster operational state.")"
  echo "$issues_json" >"$OUTPUT_FILE"
  exit 0
fi

clusters_resp="${atlas_last_http_body}"

atlas_processes_json "${ATLAS_PROJECT_ID}"
processes_resp="${atlas_last_http_body:-}"
proc_http="${atlas_last_http_status:-}"
if [[ "${proc_http}" != "200" ]]; then
  processes_resp=""
fi

filtered="$(filter_clusters_by_name "$clusters_resp" "$CLUSTER_FILTER")"

severity_for_state() {
  local sn="${1:-}"
  [[ -z "${sn:-}" ]] && sn="IDLE"
  sn="${sn^^}"
  case "$sn" in
    IDLE|MONGOS_ONLY) printf '%s' "0";;
    UPDATING|PENDING_RESTART|SERVICE_UPDATING|MAINTENANCING|TENANT_RESTORE_IN_PROGRESS|TENANT_MIGRATE_IN_PROGRESS) printf '%s' "3";;
    CREATING|LOADING|SAVING|WAITING_RESTORE|SYNCING|SYNC_REQUESTED|AUTO_SCALING|SIMPLE_SSL_ROTATING|UNSYNCING) printf '%s' "3";;
    RECOVERING|PENDING_RESTORE|RESTORING|REPAIRING|ROLLBACK|RELEASE_FAILED|RESOURCE_LOCK_PROVISIONING) printf '%s' "4";;
    FAILED|STOPPED|DELETING|INTERNAL_ERROR|TENANT_RELOCATION_ERROR|UNSYNCFAILED) printf '%s' "4";;
    PAUSED_IDLE|PAUSED) printf '%s' "2";;
    *) printf '%s' "3";;
  esac
}

printf 'Operational state sweep for Atlas project %s (%s clusters after filter).\n' \
  "${ATLAS_PROJECT_ID}" "$(echo "$filtered" | jq -r 'length')"

while IFS= read -r cjson; do
  [[ -z "$cjson" ]] && continue
  nm="$(echo "$cjson" | jq -r '.name')"
  paused="$(echo "$cjson" | jq -r '.paused // false')"
  st="$(echo "$cjson" | jq -r '.stateName // .state.name // empty')"
  [[ -z "$st" ]] && st="IDLE"

  sv="$(severity_for_state "$st")"

  [[ "$paused" == "true" ]] && {
    issues_json="$(append_issue_json "$issues_json" \
      "Cluster \`${nm}\` paused — compute layer unavailable" \
      "Atlas reports paused=true with stateName=${st}. Applications cannot connect while paused." \
      3 \
      "Resume the cluster in Atlas or confirm whether this pause is an approved change window.")"
    continue
  }

  if [[ "$sv" != "0" ]]; then
    sev_out="$sv"
    issues_json="$(append_issue_json "$issues_json" \
      "Cluster \`${nm}\` not in idle operational state (${st})" \
      "Atlas cluster stateName=${st} for \`${nm}\`; availability or updates may still be transitioning." \
      "${sev_out}" \
      "Watch Atlas deployments, Atlas status page, and application error budgets; hold traffic shifts until state returns to IDLE.")"
  fi

  # Process-level signals when enumeration succeeded
  if [[ -n "$processes_resp" ]] && printf '%s' "$processes_resp" | jq -e '.results[]' >/dev/null 2>&1; then
    bad="$(printf '%s' "$processes_resp" | jq -r --arg cn "$nm" '
      [.results[]?
        | select(.typeName == "REPLICA_SECONDARY" or .typeName == "REPLICA_PRIMARY" or .typeName == "REPLICA_ARBITER")
        | select(.replicaSetName != null)
        | select(.replicaSetName == $cn or (.replicaSetName | startswith($cn + "-")))
        | select(((.healthStatus // "") | length > 0) and .healthStatus != "HEALTHY")
      ] | length')"
    if [[ "${bad:-0}" != "0" ]]; then
      sample="$(printf '%s' "$processes_resp" | jq -c --arg cn "$nm" '[.results[]?
        | select(.replicaSetName == $cn or (.replicaSetName|startswith($cn+"-")))
        | {id,userAlias,typeName,replicaSetName,healthStatus}] | .[0:6]' | head -c 1200)"
      issues_json="$(append_issue_json "$issues_json" \
        "MongoDB Atlas reports unhealthy MongoDB processes for cluster \`${nm}\`" \
        "${bad} replica processes under cluster scope show healthStatus≠HEALTHY. Sample=${sample}" \
        4 \
        "Inspect affected nodes in Atlas Metrics/Real-Time Performance; plan failovers or Atlas support escalation if quorum is impacted.")"
    fi

  fi
done < <(echo "$filtered" | jq -c '.[]')

echo "$issues_json" | jq '.' >"$OUTPUT_FILE"
printf 'Cluster state evaluation complete → %s\n' "$OUTPUT_FILE"
