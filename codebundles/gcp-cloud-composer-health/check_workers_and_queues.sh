#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# REQUIRED ENV VARS:
#   GCP_PROJECT_ID        - GCP project containing Cloud Composer environments
#   ENV_NAME              - optional; pin to a single environment name, or 'All'
#   STALE_QUEUE_AGE_MINUTES - age (min) after which a queued task is considered
#                             stale (used for guidance, default 60)
#
# Queries the Airflow REST API for running DAG runs and their queued/running
# task instances, and checks worker capacity from the environment config.
# Outputs a JSON array of issues to workers_queues_issues.json.
# -----------------------------------------------------------------------------
set -euo pipefail

: "${GCP_PROJECT_ID:?Must set GCP_PROJECT_ID}"
: "${ENV_NAME:=All}"
: "${STALE_QUEUE_AGE_MINUTES:=60}"
: "${LOCATIONS:=us-central1}"

OUTPUT_FILE="workers_queues_issues.json"
TMP_FILE="${OUTPUT_FILE}.tmp"
> "$TMP_FILE"

echo "Checking Cloud Composer worker and queue health for project: $GCP_PROJECT_ID"

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

queued_sum=0
running_sum=0

while IFS= read -r env; do
    name=$(echo "$env" | jq -r '.name')
    short_name=$(echo "$name" | awk -F'/' '{print $NF}')
    location=$(echo "$name" | awk -F'/' '{print $4}')

    if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
        continue
    fi

    echo "Checking queued/running tasks for: $short_name (location: $location)" >&2

    uri=$(get_airflow_uri "$short_name" "$location")
    if [ -z "$uri" ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" \
            '{title: ("Cannot access Airflow to check queues for environment `" + $sn + "`"),
              expected: ("Airflow should be reachable for environment `" + $sn + "`"),
              actual: ("No Airflow web server URI found for environment `" + $sn + "`"),
              severity: 3,
              details: ("No Airflow web server URI was returned for environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "`, so the Airflow REST API cannot be queried."),
              next_steps: "Confirm the environment is RUNNING and the web server is enabled.",
              environment: $sn,
              issue_type: "airflow_access_failed"}' >> "$TMP_FILE"
        continue
    fi

    dags=$(airflow_api "$uri" "/api/v1/dags?limit=200")
    if [ -z "$dags" ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" \
            '{title: ("Cannot access Airflow to check queues for environment `" + $sn + "`"),
              expected: ("The Airflow DAG list should be readable for environment `" + $sn + "`"),
              actual: ("The Airflow DAG list endpoint returned an error for environment `" + $sn + "` in location `" + $l + "`"),
              severity: 3,
              details: ("The Airflow REST API did not respond for environment `" + $sn + "` in location `" + $l + "` of project `" + $p + "`, so queue health cannot be checked."),
              next_steps: "Check Cloud Logging for web server / database connection errors, confirm the environment is RUNNING.",
              environment: $sn,
              issue_type: "airflow_access_failed"}' >> "$TMP_FILE"
        continue
    fi

    while IFS= read -r dag_id; do
        [ -z "$dag_id" ] && continue
        dag_runs=$(airflow_api "$uri" "/api/v1/dags/${dag_id}/dagRuns?state=running&limit=100")
        [ -z "$dag_runs" ] && continue
        while IFS= read -r rr; do
            rrun_id=$(echo "$rr" | jq -r '.dag_run_id // empty')
            [ -z "$rrun_id" ] && continue
            ti=$(airflow_api "$uri" "/api/v1/dags/${dag_id}/dagRuns/${rrun_id}/taskInstances?limit=200")
            [ -z "$ti" ] && continue
            q=$(echo "$ti" | jq '[.task_instances[]? | select(.state == "queued")] | length')
            r=$(echo "$ti" | jq '[.task_instances[]? | select(.state == "running")] | length')
            if [ "$q" -gt 0 ] || [ "$r" -gt 0 ]; then
                queued_sum=$((queued_sum + q))
                running_sum=$((running_sum + r))
            fi
        done < <(echo "$dag_runs" | jq -c '.dag_runs[]?')
    done < <(echo "$dags" | jq -r '.dags[]?.dag_id // empty')
done < <(echo "$envs" | jq -c '.[]')

echo "Aggregated queues: queued=${queued_sum} running=${running_sum}"

# Queue backlog detection (project-wide)
if [ "$queued_sum" -gt 0 ] && [ "$running_sum" -gt 0 ] && [ "$queued_sum" -gt "$((running_sum * 2))" ]; then
    jq -n --arg p "$GCP_PROJECT_ID" --argjson q "$queued_sum" --argjson r "$running_sum" --arg age "$STALE_QUEUE_AGE_MINUTES" \
        '{title: ("Task queue backlog in Cloud Composer project `" + $p + "`"),
          expected: ("Queued task instances should not significantly exceed running task instances in project `" + $p + "`"),
          actual: ("Project `" + $p + "` has " + ($q|tostring) + " queued task instances vs " + ($r|tostring) + " running (queue threshold considers tasks queued longer than " + $age + " minutes stale)"),
          severity: 4,
          details: ("Detected a task-instance queue backlog in project `" + $p + "`: " + ($q|tostring) + " queued vs " + ($r|tostring) + " running. A large queue indicates workers are not keeping up, causing task delays or starvation."),
          next_steps: "Scale out workers or raise scheduling/worker capacity for the affected environment(s), inspect running DAG run task logs to find slow tasks, and clear any genuinely stale queued tasks.",
          project: $p,
          queued_count: $q,
          running_count: $r,
          issue_type: "queue_backlog"}' >> "$TMP_FILE"
fi

# Per-environment worker provisioning check
while IFS= read -r env; do
    name=$(echo "$env" | jq -r '.name')
    short_name=$(echo "$name" | awk -F'/' '{print $NF}')
    location=$(echo "$name" | awk -F'/' '{print $4}')

    if [ "$ENV_NAME" != "All" ] && [ "$ENV_NAME" != "$short_name" ]; then
        continue
    fi

    desc=$(gcloud composer environments describe "$short_name" \
        --location="$location" \
        --project="$GCP_PROJECT_ID" \
        --format=json 2>/dev/null || echo "{}")
    worker_count=$(echo "$desc" | jq -r '.config.workloadsConfig.worker.count // .config.workloadsConfig.worker.minCount // "not set"')
    echo "  Worker capacity: ${worker_count}"

    if [ -z "$worker_count" ] || [ "$worker_count" = "not set" ] || [ "$worker_count" = "0" ]; then
        jq -n --arg sn "$short_name" --arg l "$location" --arg p "$GCP_PROJECT_ID" --arg wc "$worker_count" \
            '{title: ("Cloud Composer environment `" + $sn + "` has no explicit worker capacity"),
              expected: ("Cloud Composer environment `" + $sn + "` should be provisioned with explicit worker capacity"),
              actual: ("Cloud Composer environment `" + $sn + "` in location `" + $l + "` has no explicit worker count configured"),
              severity: 3,
              details: ("Environment `" + $sn + "` in project `" + $p + "` does not have explicit worker capacity set (`" + $wc + "`), so it relies on environment defaults that may under-provision under load."),
              next_steps: ("Review the worker capacity for environment `" + $sn + "` and set an explicit worker count appropriate for expected task concurrency, then re-run this check to confirm healthy provisioning."),
              environment: $sn,
              worker_count: $wc,
              issue_type: "workers_underprovisioned"}' >> "$TMP_FILE"
    fi
done < <(echo "$envs" | jq -c '.[]')

if [ -s "$TMP_FILE" ]; then
    jq -s '.' "$TMP_FILE" > "$OUTPUT_FILE"
else
    echo "[]" > "$OUTPUT_FILE"
fi
rm -f "$TMP_FILE"

echo "Worker and queue health check complete: $(jq length "$OUTPUT_FILE") issue(s) found."