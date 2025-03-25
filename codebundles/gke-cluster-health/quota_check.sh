#!/bin/bash
# region_quota_check.sh
#
# A robust script that:
#   1) Authenticates with your service account (if $GOOGLE_APPLICATION_CREDENTIALS is set).
#   2) Lists GKE clusters in the current (or $PROJECT) project.
#   3) Determines each cluster's region from its location (REGIONAL or ZONAL).
#   4) For each region, runs "gcloud compute regions describe <region>" to get usage/limit of:
#       - CPUS
#       - IN_USE_ADDRESSES
#       - SSD_TOTAL_GB (or whichever you pick for PD).
#   5) Summarizes the cluster's potential node usage and compares to free capacity.
#       - If usage > free => breach (severity=2).
#       - If usage >=80% free => approach (severity=3).
#   6) Outputs a text report (region_quota_report.txt) and a JSON issues file (region_quota_issues.json).
#
# It includes each Next Steps referencing: project name, cluster name, node pool names, region.

set -euo pipefail

DEBUG="${DEBUG:-false}"

function dbg() {
  if [ "$DEBUG" = "true" ]; then
    echo "DEBUG: $*" >&2
  fi
}

# Metrics in "gcloud compute regions describe <region>":
CPU_METRIC="CPUS"               # e.g. limit=1500, usage=146
IP_METRIC="IN_USE_ADDRESSES"
PD_METRIC="SSD_TOTAL_GB"        # or DISKS_TOTAL_GB, etc.

REPORT_FILE="region_quota_report.txt"
ISSUES_FILE="region_quota_issues.json"
TMP_ISSUES="tmp_region_issues.json"

# Safely remove old output files (no error if they don't exist):
rm -f "$REPORT_FILE" "$ISSUES_FILE" "$TMP_ISSUES"

echo "Region-based Quota Check" > "$REPORT_FILE"
echo "[" > "$TMP_ISSUES"
first_issue=true

for cmd in gcloud jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd not found in PATH." >&2
    exit 1
  fi
done

PROJECT="${PROJECT:-$(gcloud config get-value project 2>/dev/null || true)}"
if [ -z "$PROJECT" ]; then
  echo "Error: No project set. Provide PROJECT or run 'gcloud config set project <ID>'." >&2
  exit 1
fi
dbg "Using project=$PROJECT"

# 1) list GKE clusters
dbg "Listing GKE clusters..."
CLUSTERS_JSON="$(gcloud container clusters list --project="$PROJECT" --format=json || true)"
if [ -z "$CLUSTERS_JSON" ] || [ "$CLUSTERS_JSON" = "[]" ]; then
  echo "No GKE clusters found in project $PROJECT" >> "$REPORT_FILE"
  echo "]" >> "$TMP_ISSUES"
  mv "$TMP_ISSUES" "$ISSUES_FILE"
  exit 0
fi

numClusters="$(echo "$CLUSTERS_JSON" | jq length)"
dbg "Found $numClusters clusters."

# We'll cache region quota results so we don't re-run "gcloud compute regions describe" multiple times
declare -A REGION_JSON_CACHE

function deriveRegion() {
  local cLoc="$1"
  local locType="$2"
  if [ -n "$locType" ] && [ "$locType" != "null" ]; then
    if [ "$locType" = "REGIONAL" ]; then
      echo "$cLoc"
    else
      echo "$cLoc" | sed 's|-.[a-zA-Z0-9]$||'
    fi
  else
    # fallback approach
    if [[ "$cLoc" =~ -[a-zA-Z0-9]$ ]]; then
      echo "$cLoc" | sed 's|-.[a-zA-Z0-9]$||'
    else
      echo "$cLoc"
    fi
  fi
}

function getRegionQuotasJSON() {
  local region="$1"
  if [ -n "${REGION_JSON_CACHE[$region]+_}" ]; then
    dbg "Already have region $region in cache."
    echo "${REGION_JSON_CACHE[$region]}"
    return
  fi

  dbg "Running gcloud compute regions describe $region --project=$PROJECT --format=json"
  local RJSON
  RJSON="$(gcloud compute regions describe "$region" --project="$PROJECT" --format=json 2>/dev/null || true)"
  if [ -z "$RJSON" ] || [ "$RJSON" = "null" ]; then
    dbg "No region info or error for $region"
    RJSON=""
  fi
  REGION_JSON_CACHE["$region"]="$RJSON"
  echo "$RJSON"
}

function findQuota() {
  local regionJSON="$1"
  local metric="$2"
  # each .quotas[] has "metric", "limit", "usage"
  # We'll parse the first match
  local limitVal
  limitVal="$(echo "$regionJSON" | jq -r --arg m "$metric" '
    .quotas[]? | select(.metric==$m) | .limit
  ' | head -n1 )"

  local usageVal
  usageVal="$(echo "$regionJSON" | jq -r --arg m "$metric" '
    .quotas[]? | select(.metric==$m) | .usage
  ' | head -n1 )"

  echo "$limitVal $usageVal"
}

function postIssue() {
  local T="$1"
  local D="$2"
  local S="$3"
  local R="$4"

  echo "Issue: $T" >> "$REPORT_FILE"
  echo "Details: $D" >> "$REPORT_FILE"
  echo "Severity: $S" >> "$REPORT_FILE"
  echo "Next Steps: $R" >> "$REPORT_FILE"
  echo "-----" >> "$REPORT_FILE"

  if [ "$first_issue" = true ]; then
    first_issue=false
  else
    echo "," >> "$TMP_ISSUES"
  fi
  jq -n \
    --arg title "$T" \
    --arg details "$D" \
    --arg suggested "$R" \
    --argjson severity "$S" \
    '{title:$title, details:$details, severity:$severity, suggested:$suggested}' \
    >> "$TMP_ISSUES"
}

for (( i=0; i<"$numClusters"; i++ )); do
  cName="$(echo "$CLUSTERS_JSON" | jq -r ".[$i].name")"
  cLoc="$(echo "$CLUSTERS_JSON" | jq -r ".[$i].location")"
  locType="$(echo "$CLUSTERS_JSON" | jq -r ".[$i].locationType // empty")"

  if [ -z "$cName" ] || [ "$cName" = "null" ]; then
    continue
  fi

  echo "Cluster: $cName (Location: $cLoc)" >> "$REPORT_FILE"

  # Retrieve nodepools
  dbg "Retrieving nodepools for cluster=$cName, zone=$cLoc"
  NP_JSON="$(gcloud container node-pools list \
    --cluster="$cName" --zone="$cLoc" \
    --project="$PROJECT" --format=json || true)"

  if [ -z "$NP_JSON" ] || [ "$NP_JSON" = "[]" ]; then
    echo "No node pools or error for $cName" >> "$REPORT_FILE"
    continue
  fi

  # Summation of potential usage
  totalCPUs=0
  totalNodes=0
  npCount="$(echo "$NP_JSON" | jq length)"
  declare -a nodepoolNames=()

  for (( p=0; p<npCount; p++ )); do
    npName="$(echo "$NP_JSON" | jq -r ".[$p].name")"
    nodepoolNames+=("$npName")

    autoScale="$(echo "$NP_JSON" | jq -r ".[$p].autoscaling.enabled")"
    cMax=0
    if [ "$autoScale" = "true" ]; then
      cMax="$(echo "$NP_JSON" | jq -r ".[$p].autoscaling.maxNodeCount")"
    else
      cMax="$(echo "$NP_JSON" | jq -r ".[$p].initialNodeCount")"
    fi
    [[ "$cMax" =~ ^[0-9]+$ ]] || cMax=0

    mType="$(echo "$NP_JSON" | jq -r ".[$p].config.machineType")"
    # naive parse
    cVal=4
    if [[ "$mType" =~ ([0-9]+)$ ]]; then
      cVal="${BASH_REMATCH[1]}"
    fi

    totalCPUs=$(( totalCPUs + (cMax * cVal) ))
    totalNodes=$(( totalNodes + cMax ))
  done

  nodePoolsCSV="$(IFS=,; echo "${nodepoolNames[*]}")"

  echo " => Potential total nodes: $totalNodes" >> "$REPORT_FILE"
  echo " => Potential total vCPUs: $totalCPUs" >> "$REPORT_FILE"

  # Derive region
  realRegion="$(deriveRegion "$cLoc" "$locType")"
  echo " => region derived=$realRegion" >> "$REPORT_FILE"

  # fetch region quotas
  regionJSON="$(getRegionQuotasJSON "$realRegion")"
  if [ -z "$regionJSON" ]; then
    echo " => Could not retrieve region data for $realRegion" >> "$REPORT_FILE"
    continue
  fi

  ##################################
  # 1) CPU check
  ##################################
  read -r cpuLimit cpuUsage < <(findQuota "$regionJSON" "$CPU_METRIC")
  if [ -n "$cpuLimit" ] && [ "$cpuLimit" != "null" ] && [ -n "$cpuUsage" ] && [ "$cpuUsage" != "null" ]; then
    freeCPUs="$(awk -v used="$cpuUsage" -v lim="$cpuLimit" 'BEGIN { printf "%.0f", lim - used }')"
    echo " => CPU $CPU_METRIC: limit=$cpuLimit usage=$cpuUsage free=$freeCPUs" >> "$REPORT_FILE"

    if [ "$totalCPUs" -gt "$freeCPUs" ]; then
      postIssue \
        "CPU Quota breach for GKE Cluster \`$cName\`" \
        "Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => Potential usage=$totalCPUs, free=$freeCPUs" \
        2 \
        "Request CPU quota increase or reduce autoscaling in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
    else
      ratioCPU="$(awk -v pot="$totalCPUs" -v fr="$freeCPUs" 'BEGIN{ if(fr<=0){print 999}else{print pot/fr}}')"
      check80="$(awk -v r="$ratioCPU" 'BEGIN{ if(r>=0.8)print 1;else print 0;}')"
      if [ "$check80" -eq 1 ]; then
        postIssue \
          "CPU usage approaching for GKE Cluster \`$cName\`" \
          "Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => potential usage=$totalCPUs ~80% of free=$freeCPUs" \
          3 \
          "Monitor CPU usage or request more CPU quota in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
      fi
    fi
  else
    echo " => $CPU_METRIC not found in region $realRegion" >> "$REPORT_FILE"
  fi

  ##################################
  # 2) IP check
  ##################################
  read -r ipLimit ipUsage < <(findQuota "$regionJSON" "$IP_METRIC")
  if [ -n "$ipLimit" ] && [ "$ipLimit" != "null" ] && [ -n "$ipUsage" ] && [ "$ipUsage" != "null" ]; then
    ipFree="$(awk -v u="$ipUsage" -v l="$ipLimit" 'BEGIN{ printf "%.0f", l-u }')"
    echo " => IP $IP_METRIC: limit=$ipLimit usage=$ipUsage free=$ipFree" >> "$REPORT_FILE"

    if [ "$totalNodes" -gt "$ipFree" ]; then
      postIssue \
        "IP Quota breach for GKE Cluster \`$cName\`" \
        "Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => potential node count=$totalNodes, freeIPs=$ipFree" \
        2 \
        "Request IP quota or reduce nodepool size for GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
    else
      ratioIP="$(awk -v n="$totalNodes" -v f="$ipFree" 'BEGIN{ if(f<=0){print 999}else{print n/f} }')"
      checkIP80="$(awk -v x="$ratioIP" 'BEGIN{ if(x>=0.8)print 1;else print 0;}')"
      if [ "$checkIP80" -eq 1 ]; then
        postIssue \
          "IP usage ~80% for GKE Cluster \`$cName\`" \
          "Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => nodes=$totalNodes vs freeIPs=$ipFree" \
          3 \
          "Check IP usage or request more addresses for GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
      fi
    fi
  else
    echo " => $IP_METRIC not found in region $realRegion" >> "$REPORT_FILE"
  fi

  ##################################
  # 3) PD check
  ##################################
  read -r pdLimit pdUsage < <(findQuota "$regionJSON" "$PD_METRIC")
  if [ -n "$pdLimit" ] && [ "$pdLimit" != "null" ] && [ -n "$pdUsage" ] && [ "$pdUsage" != "null" ]; then
    echo " => PD $PD_METRIC: limit=$pdLimit usage=$pdUsage" >> "$REPORT_FILE"
    # We won't guess how many GB the cluster might create.
    # If usage>limit => breach; if usage>=80% => approach
    if (( $(awk -v u="$pdUsage" -v l="$pdLimit" 'BEGIN { if(u>l)print 1;else print 0;}') )); then
      postIssue \
        "PD usage breach for GKE Cluster \`$cName\`" \
        "Project=$PROJECT region=$realRegion => usage=$pdUsage > limit=$pdLimit" \
        2 \
        "Request PD quota or reduce disk usage in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
    else
      ratioPD="$(awk -v u="$pdUsage" -v l="$pdLimit" 'BEGIN { if(l<=0){print 999}else{print u/l} }')"
      pd80="$(awk -v rpd="$ratioPD" 'BEGIN{ if(rpd>=0.8)print 1;else print 0;}')"
      if [ "$pd80" -eq 1 ]; then
        postIssue \
          "PD usage ~80% for GKE Cluster \`$cName\`" \
          "Project=$PROJECT region=$realRegion => usage=$pdUsage, limit=$pdLimit" \
          3 \
          "Monitor or request more PD quota in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
      fi
    fi
  else
    echo " => $PD_METRIC not found in region $realRegion" >> "$REPORT_FILE"
  fi

  echo "" >> "$REPORT_FILE"
done

echo "]" >> "$TMP_ISSUES"
mv "$TMP_ISSUES" "$ISSUES_FILE"

echo "Analysis done."
echo "Report: $REPORT_FILE"
echo "Issues: $ISSUES_FILE"
