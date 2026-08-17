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

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"
: "${LOCATIONS:=us-central1}"

OUTPUT_FILE="jobs_scheduler_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"

echo "Checking Cloud Composer DAG and scheduler health for project: $GCP_PROJECT_ID"

run_airflow() {
  local env_name="$1"
  local location="$2"
  shift 2
  timeout 120 gcloud composer environments run "$env_name" \
    --location="$location" \
    --project="$GCP_PROJECT_ID" \
    "$@" 2>/dev/null || true
}

# `airflow dags list-runs` requires -d/--dag-id, so list all DAGs first and
# collect their runs into a single JSON array.
list_all_dag_runs() {
  local env_name="$1" location="$2"
  local dags dag_id runs result="[]"
  dags=$(run_airflow "$env_name" "$location" dags list -- -o json)
  if [ -z "$dags" ] || ! echo "$dags" | jq empty 2>/dev/null; then
    echo ""
    return 0
  fi
  while IFS= read -r dag_id; do
    [ -z "$dag_id" ] && continue
    runs=$(run_airflow "$env_name" "$location" dags list-runs -- -d "$dag_id" -o json 2>/dev/null || echo "[]")
    result=$(jq -n --argjson a "$result" --argjson b "$runs" '$a + $b')
  done < <(echo "$dags" | jq -r '.[].dag_id')
  echo "$result"
}

envs=$(gcloud composer environments list --project="$GCP_PROJECT_ID" --locations="$LOCATIONS" --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
  echo "No Cloud Composer environments found in project $GCP_PROJECT_ID."
  echo "[]" > "$OUTPUT_FILE"
  rm -f "$TMP_FILE"
  exit 0
fi

echo "$envs" | jq -c '.[]' | while read -r env; do
  name=$(echo "$env" | jq -r '.name')
  short_name=$(echo "$name" | awk -F'/' '{print $NF}')
  location=$(echo "$name" | awk -F'/' '{print $4}')

  if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
    continue
  fi

  echo "Checking DAG and scheduler health for: $short_name (location: $location)"

  # --- Failed DAG runs ---------------------------------------------------
  dag_runs_raw=$(list_all_dag_runs "$short_name" "$location")
  if [ -z "$dag_runs_raw" ] || ! echo "$dag_runs_raw" | jq empty 2>/dev/null; then
    printf '{"title":"Cannot access Airflow to check DAG runs for environment `%s`","expected":"Airflow DAG run state should be readable for environment `%s`","actual":"Unable to query Airflow DAG runs for environment `%s` in location `%s`","severity":3,"details":"The Airflow CLI call failed for environment `%s` in location `%s` of project `%s`. This can indicate the service account lacks Airflow access, or that the environment Airflow command executor is not responding (small environments can be slow to run Airflow commands).","next_steps":"Verify the service account has Composer Viewer/User and Airflow roles, confirm the environment is RUNNING, and retry. If it persists on a small (ENVIRONMENT_SIZE_SMALL) environment, allow more time for Airflow command execution.","environment":"%s","issue_type":"airflow_access_failed"}\n' \
      "$short_name" "$short_name" "$short_name" "$location" \
      "$short_name" "$location" "$GCP_PROJECT_ID" "$short_name" >> "$TMP_FILE"
  else
    failed_runs=$(echo "$dag_runs_raw" | jq '[.[] | select(.state == "failed")]')
    failed_count=$(echo "$failed_runs" | jq 'length')
    echo "  DAG runs found: $(echo "$dag_runs_raw" | jq 'length'), failed: $failed_count"
    if [ "$failed_count" -gt 0 ]; then
      dag_ids=$(echo "$failed_runs" | jq -r '[.[].dag_id] | unique | join(", ")')
      printf '{"title":"Failed DAG runs in Cloud Composer environment `%s`","expected":"No DAG runs should be in a failed state in environment `%s`","actual":"Environment `%s` has %s failed DAG run(s) for DAG(s): %s","severity":3,"details":"Environment `%s` in location `%s` has %s failed DAG run(s). Failed DAGs indicate broken or failing pipelines that need investigation.","next_steps":"Inspect the failed DAG runs for DAG(s) %s, review the failing task logs for each run, and fix the underlying DAG code, dependencies, or external dependencies before manually re-running the DAG(s).","environment":"%s","failed_dag_count":%s,"issue_type":"failed_dag_runs"}\n' \
        "$short_name" "$short_name" "$short_name" "$failed_count" "$dag_ids" \
        "$short_name" "$location" "$failed_count" "$dag_ids" "$short_name" "$failed_count" >> "$TMP_FILE"

      # --- Failing task instances for failed DAG runs --------------------
      echo "$failed_runs" | jq -c '.[]' | while read -r fr; do
        dag_id=$(echo "$fr" | jq -r '.dag_id')
        run_id=$(echo "$fr" | jq -r '.run_id')
        task_states=$(run_airflow "$short_name" "$location" tasks states-for-dag-run -- -d "$dag_id" -r "$run_id" -o json 2>/dev/null | jq '{failed: [.[] | select(.state == "failed")], count: length}' 2>/dev/null || echo '{"failed":[],"count":0}')
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
  jobs_raw=$(run_airflow "$short_name" "$location" jobs list -- -o json)
  if [ -n "$jobs_raw" ] && echo "$jobs_raw" | jq empty 2>/dev/null; then
    scheduler_jobs=$(echo "$jobs_raw" | jq '[.[] | select(.job_type == "SchedulerJob")]')
    scheduler_not_running=$(echo "$scheduler_jobs" | jq '[.[] | select(.state != "running")] | length')
    total_schedulers=$(echo "$scheduler_jobs" | jq 'length')
    echo "  Scheduler jobs: $total_schedulers total, $scheduler_not_running not running"
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
