#!/bin/bash
# This script queries Google Container Diagnosis Recommendations and produces:
# 1) A human-readable report (recommendations_report.txt)
# 2) A JSON file (recommendations_issues.json) with details about each recommendation.
#
# The KEY CHANGE: We create a "shortTitle" based on the recommenderSubtype,
# so we don't use the entire description as the title.

set -euo pipefail

if ! command -v gcloud &>/dev/null; then
  echo "Error: gcloud not found on PATH." >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "Error: jq not found on PATH." >&2
  exit 1
fi

PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
RECOMMENDER_ID="${RECOMMENDER_ID:-google.container.DiagnosisRecommender}"
if [ -z "$PROJECT" ]; then
  echo "Error: No project set. Use GCP_PROJECT_ID or 'gcloud config set project <PROJECT_ID>'." >&2
  exit 1
fi

REPORT_FILE="recommendations_report.txt"
ISSUES_FILE="recommendations_issues.json"
TEMP_DIR="${CODEBUNDLE_TEMP_DIR:-.}"
TEMP_ISSUES="$TEMP_DIR/recommendations_issues_temp_$$.json"

# Safely remove old files if they exist
rm -f "$REPORT_FILE" "$ISSUES_FILE" "$TEMP_ISSUES"

{
  echo "GKE Clusters Recommendations Report"
  echo "Project: $PROJECT"
  echo "Recommender: $RECOMMENDER_ID"
  echo "-------------------------------------"
} > "$REPORT_FILE"

echo "[" > "$TEMP_ISSUES"
first_issue=true

echo "Fetching GKE clusters for project '$PROJECT'..."
CLUSTERS_JSON="$(gcloud container clusters list --project="$PROJECT" --format=json || true)"
if [ -z "$CLUSTERS_JSON" ] || [ "$CLUSTERS_JSON" = "[]" ]; then
  echo "No GKE clusters found. Exiting."
  exit 0
fi

LOCATIONS="$(echo "$CLUSTERS_JSON" | jq -r '.[].location' | sort -u)"
if [ -z "$LOCATIONS" ]; then
  echo "No cluster locations found. Exiting."
  exit 1
fi

for loc in $LOCATIONS; do
  {
    echo ""
    echo "Location: $loc"
    echo "-------------------------------------"
  } >> "$REPORT_FILE"

  RECOMMENDATIONS_JSON="$(
    gcloud recommender recommendations list \
      --project="$PROJECT" \
      --location="$loc" \
      --recommender="$RECOMMENDER_ID" \
      --format=json 2>/dev/null || true
  )"

  if [ -z "$RECOMMENDATIONS_JSON" ] || [ "$RECOMMENDATIONS_JSON" = "[]" ]; then
    echo "No recommendations found for location '$loc'." >> "$REPORT_FILE"
    continue
  fi

  num_recs="$(echo "$RECOMMENDATIONS_JSON" | jq length)"
  for i in $(seq 0 $((num_recs - 1))); do
    DESCRIPTION="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].description")"
    NAME="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].name")"
    PRIORITY="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].priority // empty")"
    RECOMMENDER_SUBTYPE="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].recommenderSubtype // empty")"
    STATE="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].stateInfo.state // empty")"
    ETAG="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].etag // empty")"
    REFRESH="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].lastRefreshTime // empty")"
    PRIMARY_IMPACT="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].primaryImpact.category // empty")"
    ASSOC_INSIGHTS="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].associatedInsights[]?.insight" | paste -sd "\n" -)"
    TARGET_RESOURCES="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].targetResources[]?" | paste -sd "\n" -)"
    CONTENT_OVERVIEW="$(echo "$RECOMMENDATIONS_JSON" | jq ".[$i].content.overview")"

    # Try extracting cluster name from the resource name or overview:
    CLUSTER="$(echo "$NAME" | sed -n 's|.*/clusters/\([^/]*\)/.*|\1|p')"
    [ -z "$CLUSTER" ] && CLUSTER="UnknownCluster"
    ALT_CLUSTER="$(echo "$CONTENT_OVERVIEW" | jq -r '.targetClusters[0].clusterUri // empty' 2>/dev/null | sed 's|.*/clusters/\([^/]*\)$|\1|')"
    if [ -n "$ALT_CLUSTER" ] && [ "$ALT_CLUSTER" != "null" ]; then
      CLUSTER="$ALT_CLUSTER"
    fi

    # If description has "%s", fill it with cluster name.
    if [[ "$DESCRIPTION" == *"%s"* ]]; then
      DESCRIPTION="$(printf "$DESCRIPTION" "$CLUSTER")"
    fi

    # Convert the priority => severity
    SEVERITY=4
    case "$PRIORITY" in
      "P1") SEVERITY=1;;
      "P2") SEVERITY=2;;
      "P3") SEVERITY=3;;
      "P4") SEVERITY=4;;
      *)    SEVERITY=4;;
    esac

    #########################
    # Short Title logic:
    #  We check recommenderSubtype. If "PDB_UNPROTECTED_STATEFULSET", we do a short title like
    #  "Missing PodDisruptionBudgets for GKE Cluster `<CLUSTER>`".
    #  Otherwise, fallback to a generic "GCP Configuration Recommendation for GKE Cluster `<CLUSTER>`"
    #  or do a quick second case for "CLUSTER_BACKUP_PLAN_NOT_CREATED".
    #########################

    shortTitle=""
    case "$RECOMMENDER_SUBTYPE" in
      "PDB_UNPROTECTED_STATEFULSET")
        shortTitle="Missing PodDisruptionBudgets for GKE Cluster \`${CLUSTER}\`"
        ;;
      "CLUSTER_BACKUP_PLAN_NOT_CREATED")
        shortTitle="No Backup Plan for GKE Cluster \`${CLUSTER}\`"
        ;;
      *)
        shortTitle="GCP Configuration Recommendation for GKE Cluster \`${CLUSTER}\`"
        ;;
    esac

    # Build up the multi-line details from the various fields
    DETAILS="$DESCRIPTION"

    if [ -n "$ASSOC_INSIGHTS" ]; then
      DETAILS+="

Associated Insights:
$ASSOC_INSIGHTS"
    fi

    DETAILS+="

Content Overview:
"
    # parse targetClusters from the overview:
    TGT_CLUSTERS="$(echo "$CONTENT_OVERVIEW" | jq -r '.targetClusters[]? | "- ClusterID: " + .clusterId + ", URI: " + .clusterUri' 2>/dev/null || true)"
    if [ -n "$TGT_CLUSTERS" ]; then
      DETAILS+="
Target Clusters:
$TGT_CLUSTERS

"
    fi

    # Next, parse "podDisruptionRecommendation"
    POD_DISRUPT="$(echo "$CONTENT_OVERVIEW" | jq '.podDisruptionRecommendation // empty' 2>/dev/null || true)"
    if [ -n "$POD_DISRUPT" ] && [ "$POD_DISRUPT" != "null" ]; then
      COUNT_POD="$(echo "$POD_DISRUPT" | jq length)"
      if [ "$COUNT_POD" != "0" ]; then
        DETAILS+="Pod Disruption Recommendations:"
        for pidx in $(seq 0 $((COUNT_POD - 1))); do
          PDB_INFO="$(echo "$POD_DISRUPT" | jq ".[$pidx].pdbInfo")"
          STF_INFO="$(echo "$POD_DISRUPT" | jq ".[$pidx].statefulSetInfo")"

          LABELS="$(echo "$PDB_INFO" | jq -r '.recommendedSelectorMatchLabels[]? | "\(.labelName)=\(.labelValue)"' | paste -sd ", " -)"
          [ -z "$LABELS" ] && LABELS="(none)"

          SS_NAME="$(echo "$STF_INFO" | jq -r '.statefulSetName // "N/A"')"
          SS_NS="$(echo "$STF_INFO" | jq -r '.statefulSetNamespace // "N/A"')"
          SS_UID="$(echo "$STF_INFO" | jq -r '.statefulSetUid // "N/A"')"

          DETAILS+="
 - StatefulSet: $SS_NAME (Namespace: $SS_NS, UID: $SS_UID)
   Recommended Labels: $LABELS"
        done
        DETAILS+="

"
      fi
    fi

    # Additional top-level fields
    [ -n "$RECOMMENDER_SUBTYPE" ] && [ "$RECOMMENDER_SUBTYPE" != "null" ] && \
      DETAILS+="Recommender Subtype: $RECOMMENDER_SUBTYPE
"
    [ -n "$PRIMARY_IMPACT" ] && [ "$PRIMARY_IMPACT" != "null" ] && \
      DETAILS+="Primary Impact: $PRIMARY_IMPACT
"
    [ -n "$STATE" ] && [ "$STATE" != "null" ] && \
      DETAILS+="State: $STATE
"
    [ -n "$ETAG" ] && [ "$ETAG" != "null" ] && \
      DETAILS+="ETag: $ETAG
"
    [ -n "$REFRESH" ] && [ "$REFRESH" != "null" ] && \
      DETAILS+="Last Refresh Time: $REFRESH
"
    if [ -n "$TARGET_RESOURCES" ]; then
      DETAILS+="Target Resources:
$TARGET_RESOURCES
"
    fi

    # Provide a direct single-sentence next steps
    SUGGESTED="Review this recommendation in the GCP Console: gcloud recommender recommendations describe '$NAME' --project=$PROJECT --location=$loc"

    {
      echo "Issue: $shortTitle"
      echo "Details:"
      echo "$DETAILS"
      echo "Severity: $SEVERITY"
      echo "Suggested Next Steps: $SUGGESTED"
      echo "-------------------------------------"
    } >> "$REPORT_FILE"

    if [ "$first_issue" = true ]; then
      first_issue=false
    else
      echo "," >> "$TEMP_ISSUES"
    fi

    ISSUE_JSON="$(jq -n \
      --arg title "$shortTitle" \
      --arg details "$DETAILS" \
      --arg next_steps "$SUGGESTED" \
      --argjson severity "$SEVERITY" \
      '{title: $title, details: $details, severity: $severity, next_steps: $next_steps}')"

    echo "$ISSUE_JSON" >> "$TEMP_ISSUES"

  done
done

echo "]" >> "$TEMP_ISSUES"
mv "$TEMP_ISSUES" "$ISSUES_FILE"

echo "Report generated: $REPORT_FILE"
echo "Issues file generated: $ISSUES_FILE"
