#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project containing Cloud Composer environments
#   ENV_NAME        - optional; pin to a single environment name, or 'All'
#
# Checks live job and scheduler health for each environment using the Airflow
# CLI (via `gcloud composer environments run`): failed DAG runs, failing task
# instances, and scheduler job state. Flags broken DAGs or a non-operational
# scheduler. Outputs a JSON array of issues to jobs_scheduler_issues.json.
#
# NOTE: The Airflow CLI calls below require the Airflow viewer/operator roles in
# addition to the basic Composer viewer permissions. Access failures are surfaced
# so the required roles can be granted.
# -----------------------------------------------------------------------------
set -euo pipefail
set -x

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"

OUTPUT_FILE="jobs_scheduler_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"

echo "Checking Cloud Composer DAG and scheduler health for project: $GCP_PROJECT_ID"

run_airflow() {
  local env_name="$1"
  local location="$2"
  shift 2
  gcloud composer environments run "$env_name" \
    --location="$location" \
    --project="$GCP_PROJECT_ID" \
    -- "$@" 2>/dev/null || true
}

envs=$(gcloud composer environments list --project="$GCP_PROJECT_ID" --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
  echo "No Cloud Composer environments found in project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"
  rm -f "$TMP_FILE"
  exit 0
fi

echo "$envs" | jq -c '.[]' | while read -r env; do
  name=$(echo "$env" | jq -r '.name')
  short_name=$(echo "$name" | awk -F'/' '{print $NF}')
  location=$(echo "$env" | jq -r '.location')

  if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
    continue
  fi

  echo "Checking DAG and scheduler health for: $short_name (location: $location)"

  # --- Failed DAG runs ---------------------------------------------------
  dag_runs_raw=$(run_airflow "$short_name" "$location" airflow dags list-runs -o json)
  if [ -z "$dag_runs_raw" ] || ! echo "$dag_runs_raw" | jq empty 2>/dev/null; then
    printf '{"title":"Cannot access Airflow to check DAG runs for environment `%s`","expected":"Airflow DAG run state should be readable for environment `%s`","actual":"Unable to query Airflow DAG runs for environment `%s` in location `%s`","severity":3,"details":"The Airflow CLI call failed for environment `%s` in location `%s` of project `%s`. This typically indicates the service account is missing the Airflow viewer/operator roles required to run Airflow commands.","next_steps":"Grant the service account the required Airflow roles (e.g. Composer Viewer plus an Airflow viewer/operator role) and ensure the environment is RUNNING before re-running this task.","environment":"%s","issue_type":"airflow_access_failed"}\n' \
      "$short_name" "$short_name" "$short_name" "$location" \
      "$short_name" "$location" "$GCP_PROJECT_ID" "$short_name" >> "$TMP_FILE"
  else
    failed_runs=$(echo "$dag_runs_raw" | jq '[.[] | select(.state == "failed")]')
    failed_count=$(echo "$failed_runs" | jq 'length')
    if [ "$failed_count" -gt 0 ]; then
      dag_ids=$(echo "$failed_runs" | jq -r '[.[].dag_id] | unique | join(", ")')
      printf '{"title":"Failed DAG runs in Cloud Composer environment `%s`","expected":"No DAG runs should be in a failed state in environment `%s`","actual":"Environment `%s` has %s failed DAG run(s) for DAG(s): %s","severity":3,"details":"Environment `%s` in location `%s` has %s failed DAG run(s). Failed DAGs indicate broken or failing pipelines that need investigation.","next_steps":"Inspect the failed DAG runs for DAG(s) %s, review the failing task logs for each run, and fix the underlying DAG code, dependencies, or external dependencies before manually re-running the DAG(s).","environment":"%s","failed_dag_count":%s,"issue_type":"failed_dag_runs"}\n' \
        "$short_name" "$short_name" "$short_name" "$failed_count" "$dag_ids" \
        "$short_name" "$location" "$failed_count" "$dag_ids" "$short_name" "$failed_count" >> "$TMP_FILE"

      # --- Failing task instances for failed DAG runs --------------------
      echo "$failed_runs" | jq -c '.[]' | while read -r fr; do
        dag_id=$(echo "$fr" | jq -r '.dag_id')
        run_id=$(echo "$fr" | jq -r '.run_id')
        task_states=$(run_airflow "$short_name" "$location" airflow tasks states-for-dag-run -d "$dag_id" -r "$run_id" -o json 2>/dev/null | jq '{failed: [.[] | select(.state == "failed")], count: length}' 2>/dev/null || echo '{"failed":[],"count":0}')
        failed_tasks=$(echo "$task_states" | jq -c '.failed')
        failed_task_count=$(echo "$task_states" | jq '.failed | length')
        if [ "$failed_task_count" -gt 0 ]; then
          task_ids=$(echo "$failed_tasks" | jq -r '[.[].task_id] | join(", ")')
          printf '{"title":"Failing task instances for DAG run `%s` in environment `%s`","expected":"Task instances for DAG run `%s` should not fail in environment `%s`","actual":"DAG run `%s` in environment `%s` has %s failing task instance(s): %s","severity":4,"details":"DAG run `%s` for DAG `%s` in environment `%s` (location `%s`) has %s failing task instance(s): %s.","next_steps":"Open the failing task logs for DAG `%s` run `%s`, identify the root cause (code error, missing dependency, resource limits), fix it, and clear/retry the affected task instances.","environment":"%s","dag_id":"%s","run_id":"%s","issue_type":"failing_task_instances"}\n' \
            "$run_id" "$short_name" "$run_id" "$short_name" \
            "$run_id" "$short_name" "$failed_task_count" "$task_ids" \
            "$run_id" "$dag_id" "$short_name" "$location" "$failed_task_count" "$task_ids" \
            "$dag_id" "$run_id" "$short_name" "$short_name" "$dag_id" "$run_id" >> "$TMP_FILE"
        fi
      done
    fi
  fi

  # --- Scheduler job health ---------------------------------------------
  jobs_raw=$(run_airflow "$short_name" "$location" airflow jobs list -o json)
  if [ -n "$jobs_raw" ] && echo "$jobs_raw" | jq empty 2>/dev/null; then
    scheduler_jobs=$(echo "$jobs_raw" | jq '[.[] | select(.job_type == "SchedulerJob")]')
    scheduler_not_running=$(echo "$scheduler_jobs" | jq '[.[] | select(.state != "running")] | length')
    total_schedulers=$(echo "$scheduler_jobs" | jq 'length')
    if [ "$total_schedulers" -gt 0 ] && [ "$scheduler_not_running" -gt 0 ]; then
      printf '{"title":"Airflow scheduler is not healthy in environment `%s`","expected":"Airflow scheduler jobs should be running in environment `%s`","actual":"Environment `%s` has %s scheduler job(s) that are not in a running state","severity":4,"details":"Environment `%s` in location `%s` has %s scheduler job(s) not running out of %s total scheduler job(s). A non-operational scheduler stops parsing DAGs and scheduling task instances.","next_steps":"Restart the scheduler for environment `%s` (or force a scheduler component refresh), check scheduler logs for parsing errors or OOM, and confirm DAG parsing resumes.","environment":"%s","scheduler_not_running":%s,"issue_type":"scheduler_not_healthy"}\n' \
        "$short_name" "$short_name" "$short_name" "$scheduler_not_running" \
        "$short_name" "$location" "$scheduler_not_running" "$total_schedulers" \
        "$short_name" "$short_name" "$scheduler_not_running" >> "$TMP_FILE"
    fi
  fi
done

if [ -s "$TMP_FILE" ]; then
  jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
  echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"

echo "DAG and scheduler health check complete. $(jq length "$OUTPUT_FILE") issue(s) found."
