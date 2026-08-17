---
name: gcp-cloud-composer-health
kind: skill-template
description: Identify health problems in GCP Cloud Composer (Managed Airflow) environments -- environment state, configuration drift, DAG and scheduler health, worker and queue health, and error logs. Use when triaging or monitoring GCP, Cloud Composer workloads with skill template `gcp-cloud-composer-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Cloud Composer]
resource_types: [gcp_resource]
access: read-only
---

# GCP Cloud Composer Health

## Summary

Monitors GCP Cloud Composer (Managed Apache Airflow) environments for overall health: environment state, full configuration (airflow/image version, scheduler/worker/node counts, web server, networking), live DAG run and task-instance health, scheduler health, worker/queue health, and Cloud Logging error entries per environment.

See [README.md](README.md) for additional context.

## Tools

### Check Cloud Composer Environment Health State in GCP Project `${GCP_PROJECT_ID}`

Lists all Cloud Composer environments in the project and flags any that are not in a healthy `RUNNING` state (`ERROR`, `CREATING`, `UPDATING`, `DELETING`, or degraded).

- **Robot task name**: <code>Check Cloud Composer Environment Health State in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_env_state.sh`
- **Tags**: `gcloud`, `composer`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`
- **Writes**: `env_state_issues.json`
- **Issues raised**: severity 3 per environment not in `RUNNING` state

### Fetch Cloud Composer Environment Configurations in GCP Project `${GCP_PROJECT_ID}`

Dumps full environment configuration (airflow version, software config, scheduler/worker/node counts, web server, image version, networking) and flags missing or misconfigured settings, including environments using outdated or non-LTS airflow versions.

- **Robot task name**: <code>Fetch Cloud Composer Environment Configurations in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `fetch_env_config.sh`
- **Tags**: `gcloud`, `composer`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:config`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`
- **Writes**: `env_config_issues.json`, `env_config_report.json`
- **Issues raised**: severity 2 (missing web server) / severity 3 (outdated or non-LTS image/airflow) per environment

### Check Cloud Composer DAG and Scheduler Health in GCP Project `${GCP_PROJECT_ID}`

Checks live job states: failed DAG runs, failing task instances, DAG list risks, and scheduler jobs; flags broken DAGs or a non-operational scheduler.

- **Robot task name**: <code>Check Cloud Composer DAG and Scheduler Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_jobs_and_scheduler.sh`
- **Tags**: `gcloud`, `composer`, `airflow`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:runtime`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`
- **Writes**: `jobs_scheduler_issues.json`
- **Issues raised**: severity 3 (failed DAG runs / Airflow access) / severity 4 (failing task instances, unhealthy scheduler)

### Check Cloud Composer Worker and Queue Health in GCP Project `${GCP_PROJECT_ID}`

Checks Airflow queue and worker states: size of the task-instance queue, tasks queued vs running, and worker provisioning; flags queue backlogs or under/over-provisioned workers.

- **Robot task name**: <code>Check Cloud Composer Worker and Queue Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_workers_and_queues.sh`
- **Tags**: `gcloud`, `composer`, `airflow`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:runtime`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`, `STALE_QUEUE_AGE_MINUTES`
- **Writes**: `workers_queues_issues.json`
- **Issues raised**: severity 3 (workers under-provisioned / Airflow access) / severity 4 (queue backlog)

### Get Error Logs for Cloud Composer Environments in GCP Project `${GCP_PROJECT_ID}`

Scans Cloud Logging (`resource.type=cloud_composer_environment`) for `ERROR` and higher severity entries over the lookback window and groups them per environment, surfacing the most common failures.

- **Robot task name**: <code>Get Error Logs for Cloud Composer Environments in GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `get_error_logs.sh`
- **Tags**: `gcloud`, `composer`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:logs-config`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`, `LOG_LOOKBACK_WINDOW_DAYS`
- **Writes**: `error_logs_issues.json`
- **Issues raised**: severity 3 per environment with `ERROR`+ log entries

### Generate Cloud Composer Health Summary for GCP Project `${GCP_PROJECT_ID}`

Aggregates environment state, job health, worker/queue health, and error-log findings into a normalized summary table and next-steps for each environment in the project.

- **Robot task name**: <code>Generate Cloud Composer Health Summary for GCP Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `composer_health_summary.sh`
- **Tags**: `gcloud`, `composer`, `gcp`, `${GCP_PROJECT_ID}`, `access:read-only`, `data:mix`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`
- **Writes**: `composer_health_summary_issues.json`
- **Issues raised**: severity 3 per environment that requires attention (non-RUNNING)

## Monitor

This SLI scores GCP Cloud Composer health by evaluating environment state, configuration health, DAG/scheduler health, worker/queue health, and error logs. Produces a value between 0 (completely failing) and 1 (fully healthy).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `300s`

### Sub-checks

#### Score Cloud Composer Environment State in GCP Project `${GCP_PROJECT_ID}`

Scores 1.0 if every Cloud Composer environment is `RUNNING`, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud Composer Environment State in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `environment_state`, `unhealthy_environment_count`
- **Underlying script**: `check_env_state.sh`
- **Tags**: `gcloud`, `composer`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`
- **Pass condition**: `unhealthy_environment_count == 0`

#### Score Cloud Composer Configuration Health in GCP Project `${GCP_PROJECT_ID}`

Scores 1.0 if no environment configuration issues are found, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud Composer Configuration Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `config_health`, `config_issue_count`
- **Underlying script**: `fetch_env_config.sh`
- **Tags**: `gcloud`, `composer`, `gcp`, `${GCP_PROJECT_ID}`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`
- **Pass condition**: `config_issue_count == 0`

#### Score Cloud Composer DAG and Scheduler Health in GCP Project `${GCP_PROJECT_ID}`

Scores 1.0 if no failed DAG runs, failing task instances, or scheduler issues are found, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud Composer DAG and Scheduler Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `dag_scheduler_health`, `jobs_scheduler_issue_count`
- **Underlying script**: `check_jobs_and_scheduler.sh`
- **Tags**: `gcloud`, `composer`, `airflow`, `gcp`, `${GCP_PROJECT_ID}`, `data:runtime`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`
- **Pass condition**: `jobs_scheduler_issue_count == 0`

#### Score Cloud Composer Worker and Queue Health in GCP Project `${GCP_PROJECT_ID}`

Scores 1.0 if no queue backlogs or worker provisioning issues are found, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud Composer Worker and Queue Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `worker_queue_health`, `workers_queues_issue_count`
- **Underlying script**: `check_workers_and_queues.sh`
- **Tags**: `gcloud`, `composer`, `airflow`, `gcp`, `${GCP_PROJECT_ID}`, `data:runtime`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`, `STALE_QUEUE_AGE_MINUTES`
- **Pass condition**: `workers_queues_issue_count == 0`

#### Score Cloud Composer Error Log Health in GCP Project `${GCP_PROJECT_ID}`

Scores 1.0 if no `ERROR`+ environment log entries are found, 0.0 otherwise.

- **Robot task name**: <code>Score Cloud Composer Error Log Health in GCP Project `${GCP_PROJECT_ID}`</code>
- **Sub-metric names**: `error_log_health`, `error_log_environment_count`
- **Underlying script**: `get_error_logs.sh`
- **Tags**: `gcloud`, `composer`, `gcp`, `${GCP_PROJECT_ID}`, `data:logs-config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `ENV_NAME`, `LOG_LOOKBACK_WINDOW_DAYS`
- **Pass condition**: `error_log_environment_count == 0`

## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP Project ID that contains the Cloud Composer environments to check. | — | yes |
| `ENV_NAME` | string | Pin monitoring to a single Composer environment name; `All` auto-discovers every environment in the project. | `All` | no |
| `LOG_LOOKBACK_WINDOW_DAYS` | string | Number of days back to scan Cloud Logging for error entries. | `14` | no |
| `STALE_QUEUE_AGE_MINUTES` | string | Age in minutes after which a queued task instance is considered stale/backlogged. | `60` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- Sub-metrics per health dimension with raw issue counts
- `env_state_issues.json`
- `env_config_issues.json`
- `env_config_report.json`
- `jobs_scheduler_issues.json`
- `workers_queues_issues.json`
- `error_logs_issues.json`
- `composer_health_summary_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-cloud-composer-health/runbook.robot`
- **Monitor**: `codebundles/gcp-cloud-composer-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-cloud-composer-health
export GCP_PROJECT_ID=...
export ENV_NAME=All
export LOG_LOOKBACK_WINDOW_DAYS=14
export STALE_QUEUE_AGE_MINUTES=60
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-cloud-composer-health
export GCP_PROJECT_ID=...
export ENV_NAME=All
export LOG_LOOKBACK_WINDOW_DAYS=14
export STALE_QUEUE_AGE_MINUTES=60
bash check_env_state.sh
bash fetch_env_config.sh
bash check_jobs_and_scheduler.sh
bash check_workers_and_queues.sh
bash get_error_logs.sh
bash composer_health_summary.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring across five health dimensions
- `check_env_state.sh` — flags environments not in a healthy `RUNNING` state
- `fetch_env_config.sh` — dumps environment config and flags outdated/misconfigured settings
- `check_jobs_and_scheduler.sh` — checks failed DAG runs, failing tasks, and scheduler health
- `check_workers_and_queues.sh` — checks queue backlogs and worker provisioning
- `get_error_logs.sh` — scans Cloud Logging for `ERROR`+ entries per environment
- `composer_health_summary.sh` — aggregates findings into a normalized health summary table
