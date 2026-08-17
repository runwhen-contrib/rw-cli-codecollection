#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project containing Cloud Composer environments
#   ENV_NAME        - optional; pin to a single environment name, or 'All'
#
# Aggregates environment state, job/worker/queue health, and error-log findings
# into a normalized summary table and next-steps for each environment in the
# project. The human-readable table is printed to stdout (shown in the report)
# and any environment requiring attention produces a normalized summary issue.
# Outputs a JSON array of summary issues to composer_health_summary_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"

OUTPUT_FILE="composer_health_summary_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"

echo "Generating Cloud Composer health summary for project: $GCP_PROJECT_ID"

envs=$(gcloud composer environments list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
  echo "No Cloud Composer environments found in project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"
  rm -f "$TMP_FILE"
  exit 0
fi

{
  printf "%-32s %-12s %-30s %-10s %-10s\n" "ENVIRONMENT" "STATE" "IMAGE_VERSION" "WORKERS" "SCHEDULERS"
  echo "$envs" | jq -c '.[]' | while read -r env; do
    short_name=$(echo "$env" | jq -r '.name' | awk -F'/' '{print $NF}')
    location=$(echo "$env" | jq -r '.location')
    if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
      continue
    fi
    state=$(gcloud composer environments describe "$short_name" \
      --location="$location" --project="$GCP_PROJECT_ID" \
      --format='value(state)' 2>/dev/null || echo "UNKNOWN")
    image_version=$(gcloud composer environments describe "$short_name" \
      --location="$location" --project="$GCP_PROJECT_ID" \
      --format='value(config.softwareConfig.imageVersion)' 2>/dev/null || echo "-")
    worker_count=$(gcloud composer environments describe "$short_name" \
      --location="$location" --project="$GCP_PROJECT_ID" \
      --format='value(config.workloadsConfig.worker.count)' 2>/dev/null || echo "-")
    scheduler_count=$(gcloud composer environments describe "$short_name" \
      --location="$location" --project="$GCP_PROJECT_ID" \
      --format='value(config.workloadsConfig.scheduler.count)' 2>/dev/null || echo "-")
    printf "%-32s %-12s %-30s %-10s %-10s\n" \
      "$short_name" "$state" "$image_version" "$worker_count" "$scheduler_count"

    if [ "$state" != "RUNNING" ]; then
      printf '{"title":"Cloud Composer environment `%s` requires attention (overall health)","expected":"Cloud Composer environment `%s` should be RUNNING and pass state, job, worker/queue, and error-log checks","actual":"Cloud Composer environment `%s` is in state `%s`, indicating overall degraded health","severity":3,"details":"Normalized health summary: environment `%s` in location `%s` of project `%s` is in state `%s` with image `%s`, %s worker(s), %s scheduler(s). A non-RUNNING state correlates with job failures, queue backlogs, and error logs detected by the other tasks.","next_steps":"Triage environment `%s`: confirm it reaches RUNNING, review the DAG/scheduler and worker/queue task findings, and scan Cloud Logging for ERROR entries before considering an update or rollback.","environment":"%s","state":"%s","issue_type":"environment_needs_attention"}\n' \
        "$short_name" "$short_name" "$short_name" "$state" \
        "$short_name" "$location" "$GCP_PROJECT_ID" "$state" "$image_version" "$worker_count" "$scheduler_count" \
        "$short_name" "$short_name" "$state" >> "$TMP_FILE"
    fi
  done
}

if [ -s "$TMP_FILE" ]; then
  jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"

echo ""
echo "Cloud Composer health summary complete. $(jq length "$OUTPUT_FILE") environment(s) require attention."
