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
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
TMP_ISSUES="$TEMP_DIR/tmp_region_issues_$$.json"

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
  local SUMMARY="${5:-}"
  local OBSERVATIONS="${6:-[]}"

  echo "Issue: $T" >> "$REPORT_FILE"
  echo "Details: $D" >> "$REPORT_FILE"
  echo "Severity: $S" >> "$REPORT_FILE"
  echo "Next Steps: $R" >> "$REPORT_FILE"
  echo "Summary: $SUMMARY" >> "$REPORT_FILE"
  echo "Observations: $OBSERVATIONS" >> "$REPORT_FILE"
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
    --arg summary "$SUMMARY" \
    --argjson observations "$OBSERVATIONS" \
    '{title:$title, details:$details, severity:$severity, suggested:$suggested, summary:$summary, observations:$observations}' \
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

  # Get cluster details to determine zone count for regional clusters
  CLUSTER_DETAILS="$(gcloud container clusters describe "$cName" --zone="$cLoc" \
    --project="$PROJECT" --format="json(locations,locationType)" 2>/dev/null || echo '{}')"
  
  CLUSTER_LOC_TYPE="$(echo "$CLUSTER_DETAILS" | jq -r '.locationType // "ZONAL"')"
  CLUSTER_ZONES="$(echo "$CLUSTER_DETAILS" | jq -r '.locations[]?' | wc -l)"
  
  # Default to 1 zone if we can't determine
  [[ "$CLUSTER_ZONES" =~ ^[0-9]+$ ]] && [ "$CLUSTER_ZONES" -gt 0 ] || CLUSTER_ZONES=1
  
  echo "  Cluster type: $CLUSTER_LOC_TYPE across $CLUSTER_ZONES zones" >> "$REPORT_FILE"

  # Summation of potential usage
  totalCPUs=0
  totalNodes=0
  totalMinCPUs=0
  totalMinNodes=0
  npCount="$(echo "$NP_JSON" | jq length)"
  declare -a nodepoolNames=()

  for (( p=0; p<npCount; p++ )); do
    npName="$(echo "$NP_JSON" | jq -r ".[$p].name")"
    nodepoolNames+=("$npName")

    autoScale="$(echo "$NP_JSON" | jq -r ".[$p].autoscaling.enabled")"
    cMin=0
    cMax=0
    if [ "$autoScale" = "true" ]; then
      cMin="$(echo "$NP_JSON" | jq -r ".[$p].autoscaling.minNodeCount")"
      cMax="$(echo "$NP_JSON" | jq -r ".[$p].autoscaling.maxNodeCount")"
    else
      # For non-autoscaling pools, min and max are the same (initialNodeCount)
      cMin="$(echo "$NP_JSON" | jq -r ".[$p].initialNodeCount")"
      cMax="$cMin"
    fi
    [[ "$cMin" =~ ^[0-9]+$ ]] || cMin=0
    [[ "$cMax" =~ ^[0-9]+$ ]] || cMax=0

    mType="$(echo "$NP_JSON" | jq -r ".[$p].config.machineType")"
    # naive parse - extract CPU count from machine type
    cVal=4
    if [[ "$mType" =~ ([0-9]+)$ ]]; then
      cVal="${BASH_REMATCH[1]}"
    fi

    totalMinCPUs=$(( totalMinCPUs + (cMin * cVal) ))
    totalMinNodes=$(( totalMinNodes + cMin ))
    totalCPUs=$(( totalCPUs + (cMax * cVal) ))
    totalNodes=$(( totalNodes + cMax ))
    
    # Add note about zone distribution for multi-zone clusters
    if [ "$CLUSTER_ZONES" -gt 1 ]; then
      zoneNote=" (distributed across $CLUSTER_ZONES zones)"
    else
      zoneNote=""
    fi
    
    echo "  Pool $npName: $cMin-$cMax nodes total ($mType, ${cVal}vCPU each)$zoneNote" >> "$REPORT_FILE"
  done

  nodePoolsCSV="$(IFS=,; echo "${nodepoolNames[*]}")"

  echo " => Minimum total nodes: $totalMinNodes (baseline always running)" >> "$REPORT_FILE"
  echo " => Maximum total nodes: $totalNodes (if fully scaled out)" >> "$REPORT_FILE"
  echo " => Minimum total vCPUs: $totalMinCPUs" >> "$REPORT_FILE"
  echo " => Maximum total vCPUs: $totalCPUs" >> "$REPORT_FILE"

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

    # Check if minimum required CPUs exceed available quota
    if [ "$totalMinCPUs" -gt "$freeCPUs" ]; then
      title="CPU Quota breach for GKE Cluster \`$cName\` (minimum requirements)"
      details="Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => Minimum required CPUs=$totalMinCPUs exceeds free=$freeCPUs"
      severity=1
      suggested="Immediately request CPU quota increase in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion. Cluster cannot maintain minimum node count."
      summary="A CPU quota breach occurred in GKE Cluster \`$cName\` within project \`$PROJECT\`, where the minimum required CPUs ($totalMinCPUs) exceeded the available quota ($freeCPUs) in region \`$realRegion\`. This prevented the cluster from maintaining its minimum node count and scaling as expected. Immediate action is needed to request a CPU quota increase and review cluster scaling configurations to ensure capacity alignment."

      observations=$(jq -nc \
        --arg cluster "$cName" \
        --arg project "$PROJECT" \
        --arg region "$realRegion" \
        --arg totalMinCPUs "$totalMinCPUs" \
        --arg freeCPUs "$freeCPUs" \
        --arg nodePoolsCSV "$nodePoolsCSV" \
        '
        [
        {
          "category": "infrastructure",
          "observation": ("Cluster `" + $cluster + "` in project `" + $project + "` exceeded its CPU quota in region `" + $region + "`, with `" + $totalMinCPUs + "` CPUs required but only `" + $freeCPUs + "` available.")
        },
        {
          "category": "operational",
          "observation": ("The CPU quota breach prevented cluster `" + $cluster + "` from maintaining its minimum node count.")
        },
        {
          "category": "configuration",
          "observation": ("NodePool `" + $nodePoolsCSV + "` in cluster `" + $cluster + "` relies on autoscaler configurations that are constrained by regional CPU quota limits.")
        }
        ]
        '
      )

      postIssue "$title" "$details" "$severity" "$suggested" "$summary" "$observations"
    # Check if maximum CPUs could exceed quota (capacity planning)
    elif [ "$totalCPUs" -gt "$freeCPUs" ]; then
      title="CPU Quota insufficient for full scale-out of GKE Cluster \`$cName\`"
      details="Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => Maximum CPUs=$totalCPUs exceeds free=$freeCPUs (minimum=$totalMinCPUs is OK)"
      severity=2
      suggested="Request CPU quota increase or reduce autoscaling maximums in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
      summary="The GKE Cluster \`$cName\` in Project \`$PROJECT\` is unable to fully scale due to an insufficient CPU quota in region \`$realRegion\`—the maximum requested CPUs (\`$totalCPUs\`) exceed the available quota (\`$freeCPUs\`). Expected behavior is for the cluster to have adequate quota for scaling. Actions needed include requesting a CPU quota increase or reducing autoscaling maximums, analyzing CPU utilization in \`$cName\`, reviewing recent scaling activity for NodePool \`$nodePoolsCSV\`, and auditing configuration or deployment changes affecting compute usage."

      observations=$(jq -nc \
        --arg cluster "$cName" \
        --arg project "$PROJECT" \
        --arg region "$realRegion" \
        --arg totalCPUs "$totalCPUs" \
        --arg freeCPUs "$freeCPUs" \
        --arg nodePoolsCSV "$nodePoolsCSV" \
        '
        [
        {
          "observation": ("The GKE Cluster `" + $cluster + "` in Project `" + $project + "` cannot scale fully because its maximum CPU request of `" + $totalCPUs + "` exceeds the available quota of `" + $freeCPUs + "` in region `" + $region + "`."),
          "category": "infrastructure"
        },
        {
          "observation": ("The NodePool `" + $nodePoolsCSV + "` in GKE Cluster `" + $cluster + "` was part of the scaling activity constrained by the CPU quota limit."),
          "category": "operational"
        },
        {
          "observation": ("The expected state for GKE Cluster `" + $cluster + "` is to have adequate CPU quota for autoscaling, but the actual state shows it is limited by available quota."),
          "category": "configuration"
        }
        ]
        '
      )

      postIssue "$title" "$details" "$severity" "$suggested" "$summary" "$observations"
    else
      # Check if we're approaching limits based on maximum usage
      ratioCPU="$(awk -v pot="$totalCPUs" -v fr="$freeCPUs" 'BEGIN{ if(fr<=0){print 999}else{print pot/fr}}')"
      check80="$(awk -v r="$ratioCPU" 'BEGIN{ if(r>=0.8)print 1;else print 0;}')"
      if [ "$check80" -eq 1 ]; then
        title="CPU usage approaching limit for GKE Cluster \`$cName\`"
        details="Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => Maximum CPUs=$totalCPUs is ~80% of free=$freeCPUs"
        severity=3
        suggested="Monitor CPU usage or request more CPU quota in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
        summary="The GKE Cluster \`$cName\` in project \`$PROJECT\` is nearing its CPU 
quota limit, with usage at approximately 80% of the \`$totalCPUs\`-CPU maximum in 
NodePool \`$nodePoolsCSV\`. Expected behavior is sufficient quota to allow scaling, 
but limited CPU availability is constraining cluster scalability. Action is needed 
to monitor CPU usage, analyze utilization and scaling patterns, and potentially 
request additional CPU quota for the \`$realRegion\` region."

        observations=$(jq -nc \
          --arg cluster "$cName" \
          --arg project "$PROJECT" \
          --arg totalCPUs "$totalCPUs" \
          --arg nodePoolsCSV "$nodePoolsCSV" \
          --arg region "$realRegion" \
          '
          [
          {
            "observation": ("The GKE Cluster `" + $cluster + "` in project `" + $project + "` is operating at approximately 80% of its allocated `" + $totalCPUs + "` CPU quota."), 
            "category": "performance"
          },
          {
            "observation": ("The GCP Project `" + $project + "` has a regional CPU quota constraint in `" + $region + "` impacting GKE cluster scalability."), 
            "category": "infrastructure"
          },
          {
            "observation": ("The cluster `" + $cluster + "` is limited by available CPU quota despite the expectation of sufficient capacity for autoscaling."), 
            "category": "configuration"
          }
          ]
          '
        )

        postIssue "$title" "$details" "$severity" "$suggested" "$summary" "$observations"
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

    # Check if minimum required IPs exceed available quota
    if [ "$totalMinNodes" -gt "$ipFree" ]; then
      title="IP Quota breach for GKE Cluster \`$cName\` (minimum requirements)"
      details="Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => Minimum required nodes=$totalMinNodes exceeds free IPs=$ipFree"
      severity=1
      suggested="Immediately request IP quota increase in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion. Cluster cannot maintain minimum node count."
      summary="A IP quota breach occurred in GKE Cluster \`$cName\` within project \`$PROJECT\`, where the minimum required nodes ($totalMinNodes) exceeded the available quota ($ipFree) in region \`$realRegion\`. This prevented the cluster from maintaining its minimum node count and scaling as expected. Immediate action is needed to request a IP quota increase and review cluster scaling configurations to ensure capacity alignment."

      observations=$(jq -nc \
        --arg cluster "$cName" \
        --arg project "$PROJECT" \
        --arg region "$realRegion" \
        --arg totalMinNodes "$totalMinNodes" \
        --arg ipFree "$ipFree" \
        --arg nodePoolsCSV "$nodePoolsCSV" \
        '
        [
        {
          "observation": ("GKE Cluster `" + $cluster + "` in Project `" + $project + "` exceeded its available IP quota with `" + $totalMinNodes + "` required nodes and only `" + $ipFree + "` free IPs."),
          "category": "infrastructure"
        },
        {
          "observation": ("The IP quota limitation prevents `" + $cluster + "` from maintaining its minimum node count."),
          "category": "infrastructure"
        },
        {
          "observation": ("The NodePool `" + $nodePoolsCSV + "` in cluster `" + $cluster + "` was unable to scale due to IP allocation constraints."),
          "category": "infrastructure"
        }
        ]
        '
      )

      postIssue "$title" "$details" "$severity" "$suggested" "$summary" "$observations"
    # Check if maximum nodes could exceed quota
    elif [ "$totalNodes" -gt "$ipFree" ]; then
      title="IP Quota insufficient for full scale-out of GKE Cluster \`$cName\`"
      details="Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => Maximum nodes=$totalNodes exceeds free IPs=$ipFree (minimum=$totalMinNodes is OK)"
      severity=2
      suggested="Request IP quota increase or reduce nodepool maximums in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
      summary="The GKE Cluster \`$cName\` in Project \`$PROJECT\` cannot scale to its 
configured maximum of \`$totalNodes\` nodes due to insufficient available IP addresses 
(\`$ipFree\` free). Expected behavior is that the cluster should have sufficient IP 
quota to support full scale-out. Action is needed to request an IP quota increase or 
reduce nodepool maximums, review subnet CIDR allocations, and analyze IP utilization 
and scaling configurations for NodePool \`$nodePoolsCSV\`."

      observations=$(jq -nc \
        --arg cluster "$cName" \
        --arg project "$PROJECT" \
        --arg region "$realRegion" \
        --arg totalNodes "$totalNodes" \
        --arg ipFree "$ipFree" \
        --arg totalMinNodes "$totalMinNodes" \
        --arg nodePoolsCSV "$nodePoolsCSV" \
        '
        [
        {
          "category": "infrastructure",
          "observation": ("GKE Cluster `" + $cluster + "` in Project `" + $project + "` has `" + $ipFree + "` free IPs for `" + $totalNodes + "` configured nodes."),
        },
        {
          "category": "network",
          "observation": ("IP quota limits block full scale-out of nodepool `" + $nodePoolsCSV + "` in cluster `" + $cluster + "` in region `" + $region + "`."),
        },
        {
          "category": "configuration",
          "observation": ("Nodepool `" + $nodePoolsCSV + "` in cluster `" + $cluster + "` is configured beyond available subnet IP capacity in `" + $region + "`.")
        }
        ]
        '
      )

      postIssue "$title" "$details" "$severity" "$suggested" "$summary" "$observations"
    else
      ratioIP="$(awk -v n="$totalNodes" -v f="$ipFree" 'BEGIN{ if(f<=0){print 999}else{print n/f} }')"
      checkIP80="$(awk -v x="$ratioIP" 'BEGIN{ if(x>=0.8)print 1;else print 0;}')"
      if [ "$checkIP80" -eq 1 ]; then
        title="IP usage approaching limit for GKE Cluster \`$cName\`"
        details="Project=$PROJECT region=$realRegion, cluster=$cName, nodePools=$nodePoolsCSV => Maximum nodes=$totalNodes is ~80% of free IPs=$ipFree"
        severity=3
        suggested="Check IP usage or request more addresses for GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
        summary="GKE Cluster \`$cName\` in Project \`$PROJECT\` is nearing its IP address 
limit, with NodePool \`$nodePoolsCSV\` using about 80% of available IPs (\`$ipFree\` remaining). 
The cluster may not be able to scale as expected due to limited IP quota. Actions needed 
include reviewing IP usage and subnet allocation efficiency, inspecting node pool scaling 
configurations, and evaluating CIDR settings for \`$cName\`."

        observations=$(jq -nc \
          --arg cluster "$cName" \
          --arg project "$PROJECT" \
          --arg region "$realRegion" \
          --arg totalNodes "$totalNodes" \
          --arg ipFree "$ipFree" \
          --arg nodePoolsCSV "$nodePoolsCSV" \
          '
          [
          {
            "observation": ("GKE Cluster `" + $cluster + "` in Project `" + $project + "` is using about 80% of its available IPs with `" + $ipFree + "` free addresses remaining."),
            "category": "infrastructure"
          },
          {
            "observation": ("NodePool `" + $nodePoolsCSV + "` within cluster `" + $cluster + "` is approaching the IP limit for maximum nodes set to `" + $totalNodes + "`."),
            "category": "configuration"
          },
          {
            "observation": ("Cluster `" + $cluster + "` is constrained by IP quota, preventing expected autoscaling behavior in GCP Project `" + $project + "`."),
            "category": "operational"
          }
          ]
          '
        )

        postIssue "$title" "$details" "$severity" "$suggested" "$summary" "$observations"
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
      title="PD usage breach for GKE Cluster \`$cName\`"
      details="Project=$PROJECT region=$realRegion => usage=$pdUsage > limit=$pdLimit"
      severity=2
      suggested="Request PD quota or reduce disk usage in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
      summary="A PD usage breach occurred in GKE Cluster \`$cName\` within Project 
\`$PROJECT\`, where disk usage (\`$pdUsage\` GB) exceeded the quota limit (\`$pdLimit\` 
GB). This prevented expected cluster scaling due to insufficient available quota. 
Action is needed to request additional PD quota or reduce disk usage in the region \`$realRegion\`."

      observations=$(jq -nc \
        --arg cluster "$cName" \
        --arg project "$PROJECT" \
        --arg region "$realRegion" \
        --arg pdUsage "$pdUsage" \
        --arg pdLimit "$pdLimit" \
        --arg nodePoolsCSV "$nodePoolsCSV" \
        '
        [
        {
          "observation": ("Persistent disk usage in GKE Cluster `" + $cluster + "` exceeded its quota limit with usage=`" + $pdUsage + "` vs limit=`" + $pdLimit + "`."),
          "category": "infrastructure"
        },
        {
          "observation": ("The quota breach occurred in GCP Project `" + $project + "` within Region `" + $region + "`, preventing expected autoscaling operations."),
          "category": "operational"
        },
        {
          "observation": ("Cluster `" + $cluster + "` shows storage saturation impacting resource scalability as indicated by `./quota_check.sh` validation script."), 
          "category": "performance" 
        }
      ]'
      )

      postIssue "$title" "$details" "$severity" "$suggested" "$summary" "$observations"
    else
      ratioPD="$(awk -v u="$pdUsage" -v l="$pdLimit" 'BEGIN { if(l<=0){print 999}else{print u/l} }')"
      pd80="$(awk -v rpd="$ratioPD" 'BEGIN{ if(rpd>=0.8)print 1;else print 0;}')"
      if [ "$pd80" -eq 1 ]; then
        title="PD usage ~80% for GKE Cluster \`$cName\`"
        details="Project=$PROJECT region=$realRegion => usage=$pdUsage, limit=$pdLimit"
        severity=3
        suggested="Monitor or request more PD quota in GCP Project \`$PROJECT\` for GKE Cluster \`$cName\` (NodePool \`$nodePoolsCSV\`) Region $realRegion."
        summary="Persistent Disk (PD) usage in GKE Cluster \`$cName\` under Project \`$PROJECT\` 
reached ~80% of its quota (\`$pdUsage\` used of \`$pdLimit\` limit) in region \`$realRegion\`, 
limiting cluster scalability. Expected behavior was sufficient quota for scaling operations. 
The issue was resolved by the task “Check for Quota Related GKE Autoscaling Issues in GCP Project 
\`$PROJECT\`,” but additional actions remain."

        observations=$(jq -nc \
          --arg cluster "$cName" \
          --arg project "$PROJECT" \
          --arg region "$realRegion" \
          --arg pdUsage "$pdUsage" \
          --arg pdLimit "$pdLimit" \
          --arg nodePoolsCSV "$nodePoolsCSV" \
          '
          [
          {
          "observation": ("PD usage in GKE Cluster `" + $cluster + "` under Project `" + $project + "` reached 80% of quota (`" + $pdUsage + "` of `" + $pdLimit + "`)."),
          "category": "infrastructure"
          },
          {
          "observation": ("Cluster `" + $cluster + "` in region `" + $region + "` is limited by PD quota, restricting autoscaling."),
          "category": "operational"
          },
          {
          "observation": ("NodePool `" + $nodePoolsCSV + "` in Cluster `" + $cluster + "` shows abnormal PD allocation patterns."),
          "category": "performance"
          }
          ]
          '
        )

        postIssue "$title" "$details" "$severity" "$suggested" "$summary" "$observations"
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
