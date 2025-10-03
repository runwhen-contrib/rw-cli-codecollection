#!/usr/bin/env bash
###############################################################################
# gke_cluster_operations.sh
#
# Outputs (persist):
#   ▸ cluster_operations_report.txt    – human report
#   ▸ cluster_operations_issues.json   – issues for Robot (only operations)
#   ▸ cluster_operations_list.txt      – ALL operations in the look‑back window
###############################################################################
# Function to extract timestamp from log line, fallback to current time
extract_log_timestamp() {
    local log_line="$1"
    local fallback_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    if [[ -z "$log_line" ]]; then
        echo "$fallback_timestamp"
        return
    fi
    
    # Try to extract common timestamp patterns
    # ISO 8601 format: 2024-01-15T10:30:45.123Z
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{3})?Z?) ]]; then
        echo "${BASH_REMATCH[1]}"
        return
    fi
    
    # Standard log format: 2024-01-15 10:30:45
    if [[ "$log_line" =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        # Convert to ISO format
        local extracted_time="${BASH_REMATCH[1]}"
        local iso_time=$(date -d "$extracted_time" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # DD-MM-YYYY HH:MM:SS format
    if [[ "$log_line" =~ ([0-9]{2}-[0-9]{2}-[0-9]{4}[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        local extracted_time="${BASH_REMATCH[1]}"
        # Convert DD-MM-YYYY to YYYY-MM-DD for date parsing
        local day=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f1)
        local month=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f2)
        local year=$(echo "$extracted_time" | cut -d' ' -f1 | cut -d'-' -f3)
        local time_part=$(echo "$extracted_time" | cut -d' ' -f2)
        local iso_time=$(date -d "$year-$month-$day $time_part" -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            echo "$iso_time"
        else
            echo "$fallback_timestamp"
        fi
        return
    fi
    
    # Fallback to current timestamp
    echo "$fallback_timestamp"
}

set -euo pipefail
IFS=$'\n\t'

############################  USER‑TUNABLES  ##################################
CMD_TIMEOUT=${CMD_TIMEOUT:-90}
OP_LOOKBACK_HOURS=${OP_LOOKBACK_HOURS:-24}
STUCK_HOURS=${STUCK_HOURS:-2}
VERBOSE=${VERBOSE:-1}
###############################################################################
log()  { local lvl=$1; shift; ((lvl<=VERBOSE)) && printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2; }
(( VERBOSE > 1 )) && set -x

iso() {                       # arg: hours → ISO‑8601 negative duration
  local hours=$1
  local days=$(( hours / 24 ))
  local rem=$(( hours % 24 ))
  if   (( days > 0 && rem == 0 )); then
       printf -- "-P%uD"        "$days"
  elif (( days > 0 && rem > 0 )); then
       printf -- "-P%uDT%uH"    "$days" "$rem"
  else
       printf -- "-PT%uH"       "$rem"
  fi
}
sanitize(){ tr -c 'A-Za-z0-9_.-' '_'<<<"$1"; }

###############################  GUARD  #######################################
: "${GCP_PROJECT_ID:?GCP_PROJECT_ID env var must be set}"
LOOKBACK_PERIOD=$(iso "$OP_LOOKBACK_HOURS")
NOW_EPOCH=$(date -u +%s)
log 1 "Project ${GCP_PROJECT_ID}; window ${OP_LOOKBACK_HOURS} h; stuck>${STUCK_HOURS} h"

###########################  PERSISTENT OUTPUTS  ##############################
REPORT_TXT="cluster_operations_report.txt"
OPS_LIST_TXT="cluster_operations_list.txt"
ISSUES_JSON="cluster_operations_issues.json"
rm -f "$REPORT_TXT" "$ISSUES_JSON" "$OPS_LIST_TXT"

###########################  SCRATCH + CLEANUP  ###############################
SCRATCH=()
cleanup(){ rm -f "${SCRATCH[@]}" *_ops.json 2>/dev/null || true; }
trap cleanup EXIT

#############################  FETCH CLUSTERS  ################################
timeout "$CMD_TIMEOUT"s gcloud container clusters list \
  --project "$GCP_PROJECT_ID" --format=json > clusters.json
SCRATCH+=(clusters.json)

CLUSTER_COUNT=$(jq length clusters.json)
{
  echo "# GKE Upgrade / Operation Health — project ${GCP_PROJECT_ID}"
  echo "# Collected: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "# Clusters : ${CLUSTER_COUNT}"
  echo "# Window   : ${OP_LOOKBACK_HOURS} h"
} >"$REPORT_TXT"
echo "# GKE Operations List — project ${GCP_PROJECT_ID}" >"$OPS_LIST_TXT"

if (( CLUSTER_COUNT == 0 )); then
  printf '[]\n' >"$ISSUES_JSON"
  exit 0
fi

echo "[" >"$ISSUES_JSON"
first_json=true
BLOCK_RE='^(RUNNING|PENDING|ERROR|FAILED|ABORTING)$'

###########################  MAIN CLUSTER LOOP  ###############################
while read -r cluster; do
  cname=$(jq -r '.name'<<<"$cluster")
  cloc=$(jq -r '.location'<<<"$cluster")

  echo -e "\n## Cluster: ${cname} (${cloc})" >>"$REPORT_TXT"
  echo -e "\n## Cluster: ${cname} (${cloc})" >>"$OPS_LIST_TXT"

  ### 1 – ALL operations ######################################################
  op_file="${cname}_ops.json"; SCRATCH+=("$op_file")
  timeout "$CMD_TIMEOUT"s gcloud container operations list \
    --project "$GCP_PROJECT_ID" --location "$cloc" \
    --filter="targetLink:clusters/${cname} AND startTime>${LOOKBACK_PERIOD}" \
    --limit=100000 --format=json >"$op_file" || true

  declare -A typ_count=()
  declare -A typ_running=()

  while read -r op; do
    id=$(jq -r '.name'<<<"$op")
    typ=$(jq -r '.operationType'<<<"$op")
    st=$( jq -r '.status'<<<"$op")
    ts=$( jq -r '.startTime'<<<"$op")
    te=$( jq -r '.endTime // "N/A"'<<<"$op")
    age=$(( (NOW_EPOCH-$(date -u -d "$ts" +%s))/3600 ))
    line="• ${typ} ${id} (${st}, start ${ts}, end ${te}, ${age} h)"
    echo "- $line" >>"$REPORT_TXT"
    echo  "$line" >>"$OPS_LIST_TXT"

    if [[ $st =~ $BLOCK_RE ]]; then
      sev=$([[ $st == RUNNING && $age -gt $STUCK_HOURS ]] && echo 2 || echo 3)
      next="Fetch GKE Recommendations for GCP Project \`${GCP_PROJECT_ID}\`"
      $first_json || echo "," >>"$ISSUES_JSON"; first_json=false
      jq -n --arg title "Cluster ${cname}: ${typ} ${st}" \
            --arg details "$line" \
            --arg next_steps "$next" \
            --argjson severity "$sev" \
            '{title:$title,details:$details,severity:$severity,next_steps:$next_steps}' >>"$ISSUES_JSON"
    fi

    if (( age <= STUCK_HOURS )); then
      typ_count[$typ]=$(( ${typ_count[$typ]:-0} + 1 ))
      [[ $st == RUNNING ]] && typ_running[$typ]=1
    fi
  done < <(jq -c '.[]' "$op_file")

  for t in "${!typ_count[@]}"; do
    if (( typ_count[$t] > 1 )) && [[ ${typ_running[$t]:-0} -eq 1 ]]; then
      msg="Within the last ${STUCK_HOURS}h there are ${typ_count[$t]} '${t}' operations and at least one is still RUNNING. This activity type might be stuck."
      next="Investigate '${t}' operations in cluster ${cname} (e.g. \`gcloud container operations list --project ${GCP_PROJECT_ID} --location ${cloc} --filter=\"operationType=${t}\"\`)."
      $first_json || echo "," >>"$ISSUES_JSON"; first_json=false
      jq -n --arg title "Cluster ${cname}: ${t} may be stuck" \
            --arg details "$msg" \
            --arg next_steps "$next" \
            --argjson severity 2 \
            '{title:$title,details:$details,severity:$severity,next_steps:$next_steps}' >>"$ISSUES_JSON"
    fi
  done
  unset typ_count typ_running
done < <(jq -c '.[]' clusters.json)

echo "]" >>"$ISSUES_JSON"
log 1 "✔ Report   : $REPORT_TXT"
log 1 "✔ Ops list : $OPS_LIST_TXT"
log 1 "✔ Issues   : $ISSUES_JSON"
