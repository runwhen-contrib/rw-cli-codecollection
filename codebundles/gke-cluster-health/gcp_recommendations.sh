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
  echo "Fetching recommendations for location '$loc'..."
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
    # We'll parse them carefully.
    CONTENT_OVERVIEW="$(echo "$RECOMMENDATIONS_JSON" | jq ".[$i].content.overview")"

    # We'll do the same cluster-name placeholder replacement if needed.
    # Attempt to extract a cluster name from "targetResources" or "targetClusters" if we see one.
    # Failing that, we parse from the 'name' field.
    # By default, we try the resource name in the path:
    CLUSTER="$(echo "$NAME" | sed -n 's|.*/clusters/\([^/]*\)/.*|\1|p')"
    if [ -z "$CLUSTER" ]; then
      CLUSTER="UnknownCluster"
    fi
    # If "targetClusters" has a clusterUri with a different name, use that.
    # We'll just pick the first if multiple exist.
    # E.g. content.overview.targetClusters[0].clusterUri => .../clusters/platform-cluster-01
    ALT_CLUSTER="$(echo "$CONTENT_OVERVIEW" | jq -r '.targetClusters[0].clusterUri // empty' 2>/dev/null | sed 's|.*/clusters/\([^/]*\)$|\1|')"
    if [ -n "$ALT_CLUSTER" ] && [ "$ALT_CLUSTER" != "null" ]; then
      CLUSTER="$ALT_CLUSTER"
    fi

    # If description has "%s", replace with cluster name.
    if [[ "$DESCRIPTION" == *"%s"* ]]; then
      DESCRIPTION="$(printf "$DESCRIPTION" "$CLUSTER")"
    fi

    # === Build up a "details" string that includes everything we want. ===
    DETAILS="$DESCRIPTION"

    # Append associated insights:
    if [ -n "$ASSOC_INSIGHTS" ]; then
      DETAILS+="\n\nAssociated Insights:\n$ASSOC_INSIGHTS"
    fi

    DETAILS+="\n\nContent Overview:"

    # We can parse targetClusters from the overview:
    TGT_CLUSTERS="$(echo "$CONTENT_OVERVIEW" | jq -r '.targetClusters[]? | "- ClusterID: " + .clusterId + ", URI: " + .clusterUri' 2>/dev/null || true)"
    if [ -n "$TGT_CLUSTERS" ]; then
      DETAILS+="\nTarget Clusters:\n$TGT_CLUSTERS"
    fi

    # Next, parse the "podDisruptionRecommendation" array if it exists:
    POD_DISRUPT="$(echo "$CONTENT_OVERVIEW" | jq '.podDisruptionRecommendation // empty' 2>/dev/null || true)"
    if [ -n "$POD_DISRUPT" ] && [ "$POD_DISRUPT" != "null" ]; then
      # It's an array of objects. We'll loop in bash for clarity (though you could do it purely in jq).
      COUNT_POD="$(echo "$POD_DISRUPT" | jq length)"
      if [ "$COUNT_POD" != "0" ]; then
        DETAILS+="\n\nPod Disruption Recommendations:"
        for pidx in $(seq 0 $((COUNT_POD - 1))); do
          # For each item, we get the pdbInfo + statefulSetInfo.
          PDB_INFO="$(echo "$POD_DISRUPT" | jq ".[$pidx].pdbInfo")"
          STF_INFO="$(echo "$POD_DISRUPT" | jq ".[$pidx].statefulSetInfo")"

          # recommendedSelectorMatchLabels => array of {labelName, labelValue}
          # We'll join them into labelName=labelValue strings.
          LABELS="$(echo "$PDB_INFO" | jq -r '.recommendedSelectorMatchLabels[]? | "\(.labelName)=\(.labelValue)"' | paste -sd ", " -)"
          [ -z "$LABELS" ] && LABELS="(none)"

          # parse out statefulSetName, statefulSetNamespace, statefulSetUid
          SS_NAME="$(echo "$STF_INFO" | jq -r '.statefulSetName // "N/A"')"
          SS_NS="$(echo "$STF_INFO" | jq -r '.statefulSetNamespace // "N/A"')"
          SS_UID="$(echo "$STF_INFO" | jq -r '.statefulSetUid // "N/A"')"

          DETAILS+="\n - StatefulSet: $SS_NAME (Namespace: $SS_NS, UID: $SS_UID)"
          DETAILS+="\n   Recommended Labels: $LABELS"
        done
      fi
    fi

    # Also append top-level fields from the recommendation:
    if [ -n "$RECOMMENDER_SUBTYPE" ] && [ "$RECOMMENDER_SUBTYPE" != "null" ]; then
      DETAILS+="\n\nRecommender Subtype: $RECOMMENDER_SUBTYPE"
    fi
    if [ -n "$PRIMARY_IMPACT" ] && [ "$PRIMARY_IMPACT" != "null" ]; then
      DETAILS+="\nPrimary Impact: $PRIMARY_IMPACT"
    fi
    if [ -n "$STATE" ] && [ "$STATE" != "null" ]; then
      DETAILS+="\nState: $STATE"
    fi
    if [ -n "$ETAG" ] && [ "$ETAG" != "null" ]; then
      DETAILS+="\nETag: $ETAG"
    fi
    if [ -n "$REFRESH" ] && [ "$REFRESH" != "null" ]; then
      DETAILS+="\nLast Refresh Time: $REFRESH"
    fi
    if [ -n "$TARGET_RESOURCES" ]; then
      DETAILS+="\nTarget Resources:\n$TARGET_RESOURCES"
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

    # Build the final title: e.g., "Recommendation: Create a backup plan for location-01-us-west1 in GKE Cluster location-01-us-west1"
    # We'll just take the first sentence from the updated DESCRIPTION plus the cluster name.
    TITLE="Recommendation: ${DESCRIPTION%%.*} in GKE Cluster ${CLUSTER}"

    # Create suggested steps.
    SUGGESTED="Review the recommendation in the GCP Console and run: gcloud recommender recommendations accept ${NAME} --project=${PROJECT} --location=${loc} --etag=<ETAG>"

    # Append to the human-readable report.
    {
      echo "Issue: $TITLE"
      echo "Details: $DETAILS"
      echo "Severity: $SEVERITY"
      echo "Suggested Next Steps: $SUGGESTED"
      echo "-------------------------------------"
    } >> "$REPORT_FILE"

    # Append to the JSON issues file.
    # The "kwargs" is just an empty JSON object for extensibility.
    if [ "$first_issue" = true ]; then
      first_issue=false
    else
      echo "," >> "$TEMP_ISSUES"
    fi
    ISSUE_JSON="$(jq -n \
      --arg title "$TITLE" \
      --arg details "$DETAILS" \
      --arg suggested "$SUGGESTED" \
      --argjson severity "$SEVERITY" \
      '{title: $title, details: $details, severity: $severity, suggested: $suggested, kwargs: {}}')"
    echo "$ISSUE_JSON" >> "$TEMP_ISSUES"
  done
done

echo "]" >> "$TEMP_ISSUES"
mv "$TEMP_ISSUES" "$ISSUES_FILE"

echo "Report generated: $REPORT_FILE"
echo "Issues file generated: $ISSUES_FILE"

