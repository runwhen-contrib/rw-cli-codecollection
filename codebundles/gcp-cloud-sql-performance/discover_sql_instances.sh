#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Discover Cloud SQL Instances in a GCP Project
#
# Lists all Cloud SQL database instances in the GCP project and enriches each
# with the database_id (project:instance) used for Cloud Monitoring metric
# queries, plus configuration details (tier, disk size, autoresize).
#
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID      - GCP project ID hosting the Cloud SQL instances
#   RESOURCES           - Optional comma-separated list of instance names to
#                         scope to. "All" (default) auto-discovers every instance
#
# OUTPUTS:
#   sql_config.json          - Array of enriched Cloud SQL instance objects
#   sql_instances_issues.json- JSON array of issues (usually empty on success)
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${RESOURCES:=All}"

ISSUES_FILE="sql_instances_issues.json"
CONFIG_FILE="sql_config.json"
issues_json='[]'

echo "Discovering Cloud SQL instances in project: $GCP_PROJECT_ID"

if ! instances=$(gcloud sql instances list --project="$GCP_PROJECT_ID" --format=json 2>err.log); then
    err_msg=$(cat err.log)
    rm -f err.log
    issues_json=$(echo "$issues_json" | jq \
        --arg title "Cannot access Cloud SQL instances for project \`$GCP_PROJECT_ID\`" \
        --arg details "gcloud sql instances list failed: $err_msg" \
        --arg severity "4" \
        --arg expected "Cloud SQL instances should be listable to assess performance" \
        --arg actual "Listing Cloud SQL instances failed: $err_msg" \
        --arg next_steps "Verify the service account has roles/cloudsql.viewer and that the Cloud SQL Admin API is enabled." \
        '. += [{"title":$title,"details":$details,"severity":($severity|tonumber),"expected":$expected,"actual":$actual,"next_steps":$next_steps}]')
    echo "$issues_json" > "$ISSUES_FILE"
    echo "[]" > "$CONFIG_FILE"
    echo "Discovery failed. Issues written to $ISSUES_FILE"
    exit 0
fi

if [ "$(echo "$instances" | jq 'length')" -eq 0 ]; then
    echo "No Cloud SQL instances found in project $GCP_PROJECT_ID."
    echo "[]" > "$CONFIG_FILE"
    echo "$issues_json" > "$ISSUES_FILE"
    exit 0
fi

if [ "$RESOURCES" != "All" ] && [ -n "$RESOURCES" ]; then
    names_json=$(echo "$RESOURCES" | tr ',' '\n' | jq -R . | jq -s -c .)
else
    names_json="null"
fi

echo "$instances" | jq \
    --arg GCP_PROJECT_ID "$GCP_PROJECT_ID" \
    --argjson scope "$names_json" \
    '[ .[] |
        select($scope == null or ($scope | index(.name))) |
        {
          name: .name,
          project: $GCP_PROJECT_ID,
          database_id: ($GCP_PROJECT_ID + ":" + .name),
          region: (.region // ""),
          database_version: (.databaseVersion // ""),
          state: (.state // ""),
          tier: (.settings.tier // ""),
          disk_size_gb: (.settings.diskSizeGb // 0),
          disk_autoresize: (.settings.diskAutoresize // false),
          disk_type: (.settings.diskType // ""),
          activation_policy: (.settings.activationPolicy // "")
        }
      ]' > "$CONFIG_FILE"

count=$(jq 'length' "$CONFIG_FILE")
echo "Discovered $count Cloud SQL instance(s) in project $GCP_PROJECT_ID."
jq -r '.[] | "  \(.name)  version=\(.database_version)  region=\(.region)  tier=\(.tier)  disk_gb=\(.disk_size_gb)  autoresize=\(.disk_autoresize)"' "$CONFIG_FILE"

echo "$issues_json" > "$ISSUES_FILE"
echo "Configuration dump written to $CONFIG_FILE"
