#!/bin/bash
# This script queries Google Container Diagnosis Recommendations and produces:
# 1) A human-readable report (recommendations_report.txt)
# 2) A JSON file (recommendations_issues.json) with details about each recommendation.
#
# It explicitly parses:
#  - associatedInsights
#  - content.overview.targetClusters
#  - content.overview.podDisruptionRecommendation
#  - priority => severity (P1=1, P2=2, P3=3, P4=4)
#  - other top-level fields (etag, lastRefreshTime, etc.)
#
# Fields come from the same structure as your YAML snippet, but we fetch them in JSON format
# to parse with jq.

set -euo pipefail

gcloud auth activate-service-account --key-file="$GOOGLE_APPLICATION_CREDENTIALS"

# Ensure required commands are installed.
if ! command -v gcloud &>/dev/null; then
  echo "Error: gcloud not found on PATH." >&2
  exit 1
fi
if ! command -v jq &>/dev/null; then
  echo "Error: jq not found on PATH." >&2
  exit 1
fi

# Project and Recommender ID from environment or defaults.
PROJECT="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
RECOMMENDER_ID="${RECOMMENDER_ID:-google.container.DiagnosisRecommender}"
if [ -z "$PROJECT" ]; then
  echo "Error: No project set. Use GCP_PROJECT or 'gcloud config set project <PROJECT_ID>'." >&2
  exit 1
fi

# Output files.
REPORT_FILE="recommendations_report.txt"
ISSUES_FILE="recommendations_issues.json"

# Create initial header for the report.
{
  echo "GKE Clusters Recommendations Report"
  echo "Project: $PROJECT"
  echo "Recommender: $RECOMMENDER_ID"
  echo "-------------------------------------"
} > "$REPORT_FILE"

# Temporary file to store JSON array of issues.
TEMP_ISSUES="recommendations_issues_temp.json"
echo "[" > "$TEMP_ISSUES"
first_issue=true

echo "Fetching GKE clusters for project '$PROJECT'..."
# List GKE clusters in JSON (we only need them to find unique locations).
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

# For each cluster location, fetch recommendations in JSON and parse relevant fields.
for loc in $LOCATIONS; do
  {
    echo ""
    echo "Location: $loc"
    echo "-------------------------------------"
  } >> "$REPORT_FILE"

  RECOMMENDATIONS_JSON="$(gcloud recommender recommendations list \
    --project="$PROJECT" \
    --location="$loc" \
    --recommender="$RECOMMENDER_ID" \
    --format=json || true)"

  # If none found, skip.
  if [ -z "$RECOMMENDATIONS_JSON" ] || [ "$RECOMMENDATIONS_JSON" = "[]" ]; then
    echo "No recommendations found for location '$loc'." >> "$REPORT_FILE"
    continue
  fi

  num_recs="$(echo "$RECOMMENDATIONS_JSON" | jq length)"
  for i in $(seq 0 $((num_recs - 1))); do
    # Extract top-level fields from this recommendation:
    DESCRIPTION="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].description")"
    NAME="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].name")"
    PRIORITY="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].priority // empty")"
    RECOMMENDER_SUBTYPE="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].recommenderSubtype // empty")"
    STATE="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].stateInfo.state // empty")"
    ETAG="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].etag // empty")"
    REFRESH="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].lastRefreshTime // empty")"
    # e.g. RELIABILITY, COST_OPTIMIZATION, etc.
    PRIMARY_IMPACT="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].primaryImpact.category // empty")"

    # associatedInsights => array of objects with "insight".
    ASSOC_INSIGHTS="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].associatedInsights[]?.insight" | paste -sd "\n" -)"

    # "targetResources" => e.g. ["//container.googleapis.com/projects/..."]
    TARGET_RESOURCES="$(echo "$RECOMMENDATIONS_JSON" | jq -r ".[$i].targetResources[]?" | paste -sd "\n" -)"

    # content.overview => might have "targetClusters" or "podDisruptionRecommendation".
    CONTENT_OVERVIEW="$(echo "$RECOMMENDATIONS_JSON" | jq ".[$i].content.overview")"

    # Attempt to extract a cluster name from "targetResources" or "targetClusters" if we see one.
    CLUSTER="$(echo "$NAME" | sed -n 's|.*/clusters/\([^/]*\)/.*|\1|p')"
    if [ -z "$CLUSTER" ]; then
      CLUSTER="UnknownCluster"
    fi
    ALT_CLUSTER="$(echo "$CONTENT_OVERVIEW" | jq -r '.targetClusters[0].clusterUri // empty' 2>/dev/null | sed 's|.*/clusters/\([^/]*\)$|\1|')"
    if [ -n "$ALT_CLUSTER" ] && [ "$ALT_CLUSTER" != "null" ]; then
      CLUSTER="$ALT_CLUSTER"
    fi

    # If description has "%s", replace with cluster name.
    if [[ "$DESCRIPTION" == *"%s"* ]]; then
      DESCRIPTION="$(printf "$DESCRIPTION" "$CLUSTER")"
    fi

    # Build a multi-line "details" string with real newlines.
    # We'll just keep appending with shell newlines, so the final text is truly multiline.
    DETAILS="$DESCRIPTION"

    # If we have associated insights, add them on new lines.
    if [ -n "$ASSOC_INSIGHTS" ]; then
      DETAILS+="
Associated Insights:
$ASSOC_INSIGHTS"
    fi

    DETAILS+="

Content Overview:
"

    # Parse targetClusters from the overview:
    TGT_CLUSTERS="$(echo "$CONTENT_OVERVIEW" | jq -r '.targetClusters[]? | "- ClusterID: " + .clusterId + ", URI: " + .clusterUri' 2>/dev/null || true)"
    if [ -n "$TGT_CLUSTERS" ]; then
      DETAILS+="Target Clusters:
$TGT_CLUSTERS

"
    fi

    # Next, parse the "podDisruptionRecommendation" array if it exists:
    POD_DISRUPT="$(echo "$CONTENT_OVERVIEW" | jq '.podDisruptionRecommendation // empty' 2>/dev/null || true)"
    if [ -n "$POD_DISRUPT" ] && [ "$POD_DISRUPT" != "null" ]; then
      COUNT_POD="$(echo "$POD_DISRUPT" | jq length)"
      if [ "$COUNT_POD" != "0" ]; then
        DETAILS+="Pod Disruption Recommendations:"
        for pidx in $(seq 0 $((COUNT_POD - 1))); do
          PDB_INFO="$(echo "$POD_DISRUPT" | jq ".[$pidx].pdbInfo")"
          STF_INFO="$(echo "$POD_DISRUPT" | jq ".[$pidx].statefulSetInfo")"

          # recommendedSelectorMatchLabels => array of {labelName, labelValue}
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

    # Append top-level fields
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

    # priority => severity
    SEVERITY=4
    case "$PRIORITY" in
      "P1") SEVERITY=1;;
      "P2") SEVERITY=2;;
      "P3") SEVERITY=3;;
      "P4") SEVERITY=4;;
      *)    SEVERITY=4;;
    esac

    # Create a short Title (first sentence) plus cluster name.
    TITLE="${DESCRIPTION%%.*} in GKE Cluster \`${CLUSTER}\`"

    # Provide a direct single-sentence "next steps" line.
    SUGGESTED="Open https://console.cloud.google.com/home/recommendations?project=${PROJECT} to review and apply."

    # Write human-readable report with actual newlines:
    {
      printf "Issue: %s\n" "$TITLE"
      printf "Details:\n%s\n" "$DETAILS"
      printf "Severity: %s\n" "$SEVERITY"
      printf "Suggested Next Steps: %s\n" "$SUGGESTED"
      echo "-------------------------------------"
    } >> "$REPORT_FILE"

    # Append to the JSON issues file. Newlines in $DETAILS become escaped \n in JSON (which is normal).
    if [ "$first_issue" = true ]; then
      first_issue=false
    else
      echo "," >> "$TEMP_ISSUES"
    fi
    ISSUE_JSON="$(jq -n \
      --arg title "$TITLE" \
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
