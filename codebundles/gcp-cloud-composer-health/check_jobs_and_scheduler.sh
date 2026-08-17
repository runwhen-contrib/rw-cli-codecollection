#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID  - GCP project containing Cloud Composer environments
#   ENV_NAME        - optional; pin to a single environment name, or 'All'
#
# Checks Airflow health via the Airflow REST API (web server) rather than the
# `executeAirflowCommand` CLI path: component health (scheduler / metadatabase),
# failed DAG runs, and failing task instances.
# Outputs a JSON array of issues to jobs_scheduler_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"
: "${LOCATIONS:=us-central1}"

OUTPUT_FILE="jobs_scheduler_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"

echo "Checking Cloud Composer DAG and scheduler health for project: $GCP_PROJECT_ID"

TOKEN=$(gcloud auth print-access-token 2>/dev/null)

get_airflow_uri() {
    local short_name="$1" location="$2"
    gcloud composer environments describe "$short_name" \
        --location="$location" \
        --project="$GCP_PROJECT_ID" \
        --format='value(config.airflowUri)' 2>/dev/null || echo ""
}

airflow_api() {
    local uri="$1" path="$2"
    curl -s --fail --max-time 15 \
        -H "Authorization: Bearer ${TOKEN}" \
        "${uri}${path}" 2>/dev/null || echo ""
}

envs=$(gcloud composer environments list --project="$GCP_PROJECT_ID" --locations="$LOCATIONS" --format=json 2>/dev/null || echo "[]")

if [ "$(echo "$envs" | jq 'length')" -eq 0 ]; then
    echo "No Cloud Composer environments found in project $GCP_PROJECT_ID."
    echo "[]" > "$OUTPUT_FILE"
    rm -f "$TMP_FILE"
    exit 0
fi

while IFS= read -r env; do
    name=$(echo "$env" | jq -r '.name')
    short_name=$(echo "$name" | awk -F'/' '{print $NF}')
    location=$(echo "$name" | awk -F'/' '{print $4}')

    if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
        continue
    fi

    echo "Checking DAG and scheduler health for: $short_name (location: $location)"

    uri=$(get_airflow_uri "$short_name" "$location")
    if [ -z "$uri" ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" \
            '{title: ("Cannot access Airflow for environment `" + $sn + "`"),
              expected: ("Airflow should be reachable for environment `" + $sn + "`"),
              actual: ("No Airflow web server URI found for environment `" + $sn + "` in location `" + $l + "`"),
              severity: 3,
              details: ("No Airflow web server URI was returned for environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "`, so the Airflow REST API cannot be queried."),
              next_steps: "Confirm the environment is RUNNING and the web server is enabled, then re-run this check.",
              environment: $sn,
              issue_type: "airflow_access_failed"}' >> "$TMP_FILE"
        echo "  Airflow access: no web server URI"
        continue
    fi

    health=$(airflow_api "$uri" "/api/v1/health")
    if [ -z "$health" ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" \
            '{title: ("Cannot access Airflow for environment `" + $sn + "`"),
              expected: ("The Airflow web server should respond for environment `" + $sn + "`"),
              actual: ("The Airflow web server for environment `" + $sn + "` in location `" + $l + "` is unreachable (health endpoint did not respond)"),
              severity: 3,
              details: ("The Airflow web server for environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "` did not respond to /api/v1/health. The environment data plane may be down (web server crash-looping or unreachable metadata database)."),
              next_steps: "Check Cloud Logging for web server / database connection errors, confirm the environment is RUNNING, and inspect the web server pod health.",
              environment: $sn,
              issue_type: "airflow_access_failed"}' >> "$TMP_FILE"
        echo "  Airflow access: web server unreachable"
        continue
    fi

    scheduler_status=$(echo "$health" | jq -r '.scheduler.status // "unknown"')
    metadb_status=$(echo "$health" | jq -r '.metadatabase.status // "unknown"')
    heartbeat=$(echo "$health" | jq -r '.scheduler.latest_scheduler_heartbeat // "unknown"')
    echo "  Airflow health: scheduler=${scheduler_status}, metadatabase=${metadb_status}, last scheduler heartbeat=${heartbeat}"

    if [ "$scheduler_status" != "healthy" ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" --arg st "$scheduler_status" --arg hb "$heartbeat" \
            '{title: ("Airflow scheduler is not healthy in environment `" + $sn + "`"),
              expected: ("Airflow scheduler should report healthy for environment `" + $sn + "`"),
              actual: ("Airflow scheduler for environment `" + $sn + "` reports status `" + $st + "` (last heartbeat " + $hb + ")"),
              severity: 4,
              details: ("Airflow scheduler for environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "` reports status `" + $st + "`. A non-operational scheduler stops parsing DAGs and scheduling task instances."),
              next_steps: "Restart the scheduler (or force a scheduler component refresh), check scheduler logs for parsing errors or OOM, and confirm DAG parsing resumes.",
              environment: $sn,
              issue_type: "scheduler_not_healthy"}' >> "$TMP_FILE"
    fi

    if [ "$metadb_status" != "healthy" ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" --arg st "$metadb_status" \
            '{title: ("Airflow metadata database is unhealthy in environment `" + $sn + "`"),
              expected: ("Airflow metadata database should report healthy for environment `" + $sn + "`"),
              actual: ("Airflow metadata database for environment `" + $sn + "` reports status `" + $st + "`"),
              severity: 3,
              details: ("Airflow metadata database for environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "` reports status `" + $st + "`. An unreachable metadata database breaks DAG parsing, task scheduling, and the web server."),
              next_steps: "Check Cloud Logging for sqlalchemy/database connection errors and verify the environment metadata database is reachable; recreate or repair the environment if it persists.",
              environment: $sn,
              issue_type: "metadatabase_unhealthy"}' >> "$TMP_FILE"
    fi

    dags=$(airflow_api "$uri" "/api/v1/dags?limit=200")
    if [ -z "$dags" ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" \
            '{title: ("Cannot list Airflow DAGs for environment `" + $sn + "`"),
              expected: ("The Airflow DAG list should be readable for environment `" + $sn + "`"),
              actual: ("The Airflow DAG list endpoint returned an error for environment `" + $sn + "` in location `" + $l + "`"),
              severity: 3,
              details: ("The Airflow DAG list (GET /api/v1/dags) failed for environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "` (health endpoint responded, but the DAG query did not). This typically means the metadata database query path is broken."),
              next_steps: "Check Cloud Logging for sqlalchemy/database connection errors; an unreachable metadata database breaks the DAG list query.",
              environment: $sn,
              issue_type: "dag_list_failed"}' >> "$TMP_FILE"
        continue
    fi

    dag_count=$(echo "$dags" | jq '.total_entries // 0')
    echo "  DAGs found: ${dag_count}"

    failed_dag_ids=""
    failed_run_count=0
    while IFS= read -r dag_id; do
        [ -z "$dag_id" ] && continue
        dag_runs=$(airflow_api "$uri" "/api/v1/dags/${dag_id}/dagRuns?state=failed&limit=100")
        [ -z "$dag_runs" ] && continue
        failed_count=$(echo "$dag_runs" | jq '.total_entries // 0')
        [ "$failed_count" -gt 0 ] || continue
        echo "  DAG '${dag_id}': ${failed_count} failed run(s)"
        failed_dag_ids="${failed_dag_ids}${failed_dag_ids:+, }${dag_id}"
        failed_run_count=$((failed_run_count + failed_count))

        while IFS= read -r fr; do
            run_id=$(echo "$fr" | jq -r '.dag_run_id // empty')
            [ -z "$run_id" ] && continue
            ti=$(airflow_api "$uri" "/api/v1/dags/${dag_id}/dagRuns/${run_id}/taskInstances?limit=200")
            [ -z "$ti" ] && continue
            failed_tasks=$(echo "$ti" | jq -c '[.task_instances[]? | select(.state == "failed") | .task_id]')
            failed_task_count=$(echo "$failed_tasks" | jq 'length')
            if [ "$failed_task_count" -gt 0 ]; then
                task_ids=$(echo "$failed_tasks" | jq -r 'join(", ")')
                jq -n --arg sn "$short_name" --arg dag "$dag_id" --arg run "$run_id" --arg l "$location" --arg p "$GCP_PROJECT_ID" \
                    --arg tasks "$task_ids" --argjson n "$failed_task_count" \
                    '{title: ("Failing task instances for DAG `" + $dag + "` in environment `" + $sn + "`"),
                      expected: ("Task instances for DAG run `" + $run + "` should not fail in environment `" + $sn + "`"),
                      actual: ("DAG run `" + $run + "` for DAG `" + $dag + "` has " + ($n|tostring) + " failing task instance(s): " + $tasks),
                      severity: 4,
                      details: ("DAG run `" + $run + "` for DAG `" + $dag + "` in environment `" + $sn + "` (location `" + $l + "`) has " + ($n|tostring) + " failing task instance(s): " + $tasks + "."),
                      next_steps: ("Open the failing task logs for DAG `" + $dag + "` run `" + $run + "`, identify the root cause (code error, missing dependency, resource limits), fix it, and clear/retry the affected task instances."),
                      environment: $sn,
                      dag_id: $dag,
                      run_id: $run,
                      issue_type: "failing_task_instances"}' >> "$TMP_FILE"
            fi
        done < <(echo "$dag_runs" | jq -c '.dag_runs[]?')
    done < <(echo "$dags" | jq -r '.dags[]?.dag_id // empty')

    if [ "$failed_run_count" -gt 0 ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" \
            --arg dags "$failed_dag_ids" --argjson n "$failed_run_count" \
            '{title: ("Failed DAG runs in Cloud Composer environment `" + $sn + "`"),
              expected: ("No DAG runs should be in a failed state in environment `" + $sn + "`"),
              actual: ("Environment `" + $sn + "` has " + ($n|tostring) + " failed DAG run(s) for DAG(s): " + $dags),
              severity: 3,
              details: ("Environment `" + $sn + "` in location `" + $l + "` has " + ($n|tostring) + " failed DAG run(s) across DAG(s): " + $dags + ". Failed DAGs indicate broken or failing pipelines that need investigation."),
              next_steps: ("Inspect the failed DAG runs for DAG(s) " + $dags + ", review the failing task logs, and fix the underlying DAG code, dependencies, or external dependencies."),
              environment: $sn,
              failed_dag_count: $n,
              issue_type: "failed_dag_runs"}' >> "$TMP_FILE"
    fi
done < <(echo "$envs" | jq -c '.[]')

if [ -s "$TMP_FILE" ]; then
    jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
    echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"

echo "DAG and scheduler health check complete: $(jq length "$OUTPUT_FILE") issue(s) found."
