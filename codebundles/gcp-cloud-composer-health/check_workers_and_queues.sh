#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID        - GCP project containing Cloud Composer environments
#   ENV_NAME              - optional; pin to a single environment name, or 'All'
#   STALE_QUEUE_AGE_MINUTES - age (min) after which a queued task is considered
#                             stale/backlogged (used for guidance, default 60)
#
# Checks Airflow queue and worker health across environments: tasks queued vs
# running on active DAG runs, configured worker capacity, and queue backlogs.
# Flags queue backlogs or under/over-provisioned workers.
# Outputs a JSON array of issues to workers_queues_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"
: "${STALE_QUEUE_AGE_MINUTES:=60}"

OUTPUT_FILE="workers_queues_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
SUMMARY_FILE="${OUTPUT_FILE}.summary"
> "$TMP_FILE"
> "$SUMMARY_FILE"

echo "Checking Cloud Composer worker and queue health for project: $GCP_PROJECT_ID"

run_airflow() {
  local env_name="$1"
  local location="$2"
  shift 2
  gcloud composer environments run "$env_name" \
    --location="$location" \
    --project="$GCP_PROJECT_ID" \
    -- "$@" 2>/dev/null || true
}

discover_envs() {
  gcloud composer environments list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]"
}

envs=$(discover_envs)
if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
  echo "No Cloud Composer environments found in project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"
  rm -f "$TMP_FILE" "$SUMMARY_FILE"
  exit 0
fi

# --- Aggregate queued vs running task counts across active DAG runs -----
echo "$envs" | jq -c '.[]' | while read -r env; do
  short_name=$(echo "$env" | jq -r '.name' | awk -F'/' '{print $NF}')
  location=$(echo "$env" | jq -r '.location')
  if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
    continue
  fi
  echo "Checking queued/running tasks for: $short_name (location: $location)"

  dag_runs_raw=$(run_airflow "$short_name" "$location" airflow dags list-runs -o json)
  if [ -z "$dag_runs_raw" ] || ! echo "$dag_runs_raw" | jq empty 2>/dev/null; then
    printf '{"title":"Cannot access Airflow to check queues for environment `%s`","expected":"Airflow queue state should be readable for environment `%s`","actual":"Unable to query Airflow queues for environment `%s` in location `%s`","severity":3,"details":"The Airflow CLI call failed for environment `%s` in location `%s` of project `%s`. This typically indicates the service account is missing the Airflow roles required to run Airflow commands.","next_steps":"Grant the service account the required Airflow viewer/operator roles and ensure the environment is RUNNING before re-running this task.","environment":"%s","issue_type":"airflow_access_failed"}\n' \
      "$short_name" "$short_name" "$short_name" "$location" \
      "$short_name" "$location" "$GCP_PROJECT_ID" "$short_name" >> "$TMP_FILE"
    continue
  fi

  echo "$dag_runs_raw" | jq -c '[.[] | select(.state == "running")][]' 2>/dev/null | while read -r rr; do
    dag_id=$(echo "$rr" | jq -r '.dag_id')
    run_id=$(echo "$rr" | jq -r '.run_id')
    states=$(run_airflow "$short_name" "$location" airflow tasks states-for-dag-run -d "$dag_id" -r "$run_id" -o json 2>/dev/null || echo "[]")
    if echo "$states" | jq empty 2>/dev/null; then
      q=$(echo "$states" | jq '[.[] | select(.state == "queued")] | length')
      r=$(echo "$states" | jq '[.[] | select(.state == "running")] | length')
      echo "queued_stats $q"
      echo "running_stats $r"
    fi
  done
done > "$SUMMARY_FILE"

queued_sum=0
running_sum=0
if [ -f "$SUMMARY_FILE" ]; then
  while read -r kind val; do
    case "$kind" in
      queued_stats) queued_sum=$((queued_sum + val)) ;;
      running_stats) running_sum=$((running_sum + val)) ;;
    esac
  done < "$SUMMARY_FILE"
fi
rm -f "$SUMMARY_FILE"

echo "Aggregated queues: queued=$queued_sum running=$running_sum"

# --- Queue backlog detection --------------------------------------------
if [ "$queued_sum" -gt 0 ] && [ "$running_sum" -gt 0 ] && [ "$queued_sum" -gt "$((running_sum * 2))" ]; then
  printf '{"title":"Task queue backlog in Cloud Composer project `%s`","expected":"Queued task instances should not significantly exceed running task instances","actual":"Project `%s` has %s queued task instances vs %s running task instances (queue threshold considers tasks queued longer than %s minutes stale)","severity":4,"details":"Detected a task-instance queue backlog in project `%s`: %s queued vs %s running. A large/stale queue (older than %s minutes) indicates workers are not keeping up, causing task delays or starvation.","next_steps":"Scale out workers or raise the scheduling/worker capacity for the affected environment(s), inspect running DAG run task logs to find slow tasks, and clear any genuinely stale queued tasks.","project":"%s","queued_count":%s,"running_count":%s,"issue_type":"queue_backlog"}\n' \
    "$GCP_PROJECT_ID" "$GCP_PROJECT_ID" "$queued_sum" "$running_sum" "$STALE_QUEUE_AGE_MINUTES" \
    "$GCP_PROJECT_ID" "$queued_sum" "$running_sum" "$STALE_QUEUE_AGE_MINUTES" \
    "$GCP_PROJECT_ID" "$queued_sum" "$running_sum" >> "$TMP_FILE"
fi

# --- Per-environment worker provisioning check -------------------------
echo "$envs" | jq -c '.[]' | while read -r env; do
  short_name=$(echo "$env" | jq -r '.name' | awk -F'/' '{print $NF}')
  location=$(echo "$env" | jq -r '.location')
  if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
    continue
  fi

  worker_count=$(gcloud composer environments describe "$short_name" \
    --location="$location" \
    --project="$GCP_PROJECT_ID" \
    --format='value(config.workloadsConfig.worker.count)' 2>/dev/null || echo "not set")

  if [ -z "$worker_count" ] || [ "$worker_count" = "not set" ] || [ "$worker_count" = "0" ]; then
    printf '{"title":"Cloud Composer environment `%s` has no explicit worker capacity","expected":"Cloud Composer environment `%s` should be provisioned with explicit worker capacity","actual":"Cloud Composer environment `%s` in location `%s` has no explicit worker count configured","severity":3,"details":"Environment `%s` in project `%s` does not have explicit worker capacity set (`%s`), so it relies on environment defaults that may under-provision under load.","next_steps":"Review the worker capacity for environment `%s` and set an explicit worker count appropriate for expected task concurrency, then re-run this check to confirm healthy provisioning.","environment":"%s","worker_count":"%s","issue_type":"workers_underprovisioned"}\n' \
      "$short_name" "$short_name" "$short_name" "$location" \
      "$short_name" "$GCP_PROJECT_ID" "$worker_count" "$short_name" "$short_name" "$worker_count" >> "$TMP_FILE"
  fi
done

if [ -s "$TMP_FILE" ]; then
  jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"

echo "Worker and queue health check complete. $(jq length "$OUTPUT_FILE") issue(s) found."
