#!/usr/bin/env bash
set -euo pipefail
set -x
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID
#
# This script:
#   1) Lists all Cloud Spanner instances in the project
#   2) Verifies each instance is in READY state
#   3) Reports node_count / processing_units and instance config (regional vs
#      multi-region), flagging multi-region instances provisioned with fewer
#      than 3 nodes (below Google's recommended minimum for quorum/HA)
#   4) Outputs a JSON array of issues to OUTPUT_FILE
# -----------------------------------------------------------------------------

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"

OUTPUT_FILE="instance_state_issues.json"
issues_json='[]'

echo "Checking Cloud Spanner instance state and configuration for project: $GCP_PROJECT_ID"

instances=$(gcloud spanner instances list --project="$GCP_PROJECT_ID" --format=json 2>err.log) || {
  err_msg=$(cat err.log 2>/dev/null || echo "unknown error")
  rm -f err.log
  issues_json=$(echo "$issues_json" | jq \
    --arg title "Cannot List Cloud Spanner Instances for \`$GCP_PROJECT_ID\`" \
    --arg details "gcloud spanner instances list failed: $err_msg" \
    --arg severity "3" \
    --arg expected "Cloud Spanner instances should be listable via gcloud" \
    --arg actual "The gcloud spanner instances list call failed" \
    --arg next_steps "Verify the service account has roles/spanner.viewer and that the Spanner API is enabled for the project" \
    '. += [{
       "title": $title,
       "details": $details,
       "severity": ($severity | tonumber),
       "expected": $expected,
       "actual": $actual,
       "next_steps": $next_steps
     }]')
  echo "$issues_json" > "$OUTPUT_FILE"
  jq . "$OUTPUT_FILE"
  exit 0
}
rm -f err.log

instance_count=$(echo "$instances" | jq 'length')
echo "Found $instance_count Cloud Spanner instance(s)."

if [ "$instance_count" -eq 0 ]; then
  echo "[]" > "$OUTPUT_FILE"
  echo "No Cloud Spanner instances found in project $GCP_PROJECT_ID."
  jq . "$OUTPUT_FILE"
  exit 0
fi

> /tmp/instance_state_parts.jsonl

echo "$instances" | jq -c '.[]' | while read -r inst; do
  instance_id=$(echo "$inst" | jq -r '.name' | awk -F/ '{print $NF}')
  state=$(echo "$inst" | jq -r '.state // "UNKNOWN"')
  config=$(echo "$inst" | jq -r '.config // ""' | awk -F/ '{print $NF}')
  node_count=$(echo "$inst" | jq -r '.nodeCount // 0')
  processing_units=$(echo "$inst" | jq -r '.processingUnits // 0')

  is_multi_region="true"
  case "$config" in
    regional-*) is_multi_region="false" ;;
  esac

  echo "Instance $instance_id: state=$state config=$config nodeCount=$node_count processingUnits=$processing_units multi_region=$is_multi_region"

  if [ "$state" != "READY" ]; then
    printf '{"title":"Cloud Spanner instance `%s` is not READY (state: %s)","details":"Instance `%s` in project `%s` is in state %s instead of READY. Config: %s, node_count: %s, processing_units: %s.","severity":3,"expected":"Instance state should be READY","actual":"Instance state is %s","next_steps":"Check the instance operation history via `gcloud spanner instances describe %s --project=%s` and the Cloud Console for provisioning errors.","instance":"%s"}\n' \
      "$instance_id" "$state" "$instance_id" "$GCP_PROJECT_ID" "$state" "$config" "$node_count" "$processing_units" "$state" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" >> /tmp/instance_state_parts.jsonl
  fi

  if [ "$is_multi_region" = "true" ] && [ "$node_count" -gt 0 ] && [ "$node_count" -lt 3 ]; then
    printf '{"title":"Multi-region Cloud Spanner instance `%s` under-provisioned for its config","details":"Instance `%s` uses multi-region config `%s` but has only %s node(s). Google recommends at least 3 nodes for multi-region configs to maintain quorum and availability.","severity":2,"expected":"Multi-region instances should have at least 3 nodes","actual":"Instance has %s node(s)","next_steps":"Scale the instance up via `gcloud spanner instances update %s --nodes=3 --project=%s` or migrate to a regional config if multi-region availability is not required.","instance":"%s"}\n' \
      "$instance_id" "$instance_id" "$config" "$node_count" "$node_count" "$instance_id" "$GCP_PROJECT_ID" "$instance_id" >> /tmp/instance_state_parts.jsonl
  fi
done

if [ -s /tmp/instance_state_parts.jsonl ]; then
  jq -s '.' /tmp/instance_state_parts.jsonl > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f /tmp/instance_state_parts.jsonl

echo "Instance state check completed. Found $(jq length "$OUTPUT_FILE") issue(s)."
jq . "$OUTPUT_FILE"
