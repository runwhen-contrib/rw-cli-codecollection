#!/usr/bin/env bash
###############################################################################
# gke_cluster_operations.sh
#
# Outputs (persist):
#   ▸ cluster_operations_report.txt    – human report
#   ▸ cluster_operations_issues.json   – issues for Robot (only operations)
#   ▸ cluster_operations_list.txt      – ALL operations in the look‑back window
###############################################################################
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
      observed_at=$(if [[ "$te" == "N/A" ]]; then date -u +%Y-%m-%dT%H:%M:%SZ; else echo "$te"; fi)
      $first_json || echo "," >>"$ISSUES_JSON"; first_json=false

      title="Cluster ${cname}: ${typ} ${st}"
      details="$line"
      next_steps="$next"
      
      summary="The ${typ} operation for the GKE Cluster \`${cname}\` in location \`${cloc}\` \
failed after running for approximately ${age} hours. The ${typ} operation was expected to complete \
without becoming stuck, but GKE cluster operations appeared to be stalled. \
Further action is needed to investigate ${typ} failure logs, analyze control plane upgrade events, \
and review node pool configurations and version alignment for the affected cluster \`${cname}\`."
      
      jq -n --arg title "$title" \
            --arg details "$details" \
            --arg next_steps "$next_steps" \
            --arg observed_at "$observed_at" \
            --argjson severity $sev \
            --arg summary "$summary" \
            '{title:$title,details:$details,severity:$severity,next_steps:$next_steps,summary:$summary,observed_at:$observed_at}' >>"$ISSUES_JSON"
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

      title="Cluster ${cname}: ${t} may be stuck"
      details="$msg"
      next_steps="$next"
      severity=2
      summary="The GKE cluster \`${cname}\` has ${typ_count[$t]} recent \`${t}\` operations, with at least one still RUNNING, indicating the operation may be stuck. Further investigation of the cluster operations may be required from a cluster administrator."


      jq -n --arg title "Cluster ${cname}: ${t} may be stuck" \
            --arg details "$msg" \
            --arg next_steps "$next" \
            --argjson severity $severity \
            --arg summary "$summary" \
            '{title:$title,details:$details,severity:$severity,next_steps:$next_steps,summary:$summary}' >>"$ISSUES_JSON"
    fi
  done
  unset typ_count typ_running
done < <(jq -c '.[]' clusters.json)

echo "]" >>"$ISSUES_JSON"
log 1 "✔ Report   : $REPORT_TXT"
log 1 "✔ Ops list : $OPS_LIST_TXT"
log 1 "✔ Issues   : $ISSUES_JSON"
