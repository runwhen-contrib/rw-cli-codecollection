# GCP Cloud Composer Health

This CodeBundle monitors GCP Cloud Composer (Managed Apache Airflow) environments for overall health: environment state, live job (DAG run / task instance) and queue states, configuration drift, and error logs, surfacing issues so reports and SLIs accurately represent the health of each environment.

> Note: Automatic discovery via the RunWhen Local Discovery Process is scoped at the GCP project level (`gcp_composer_environments`). The tasks support both a single pinned environment and all discovered environments in the project.

## Overview

This bundle monitors the following for each GCP project:

- **Environment state**: Flags environments that are not in a healthy `RUNNING` state (e.g. `ERROR`, `CREATING`, `UPDATING`, `DELETING`, or degraded).
- **Environment configuration**: Dumps full config (airflow/image version, scheduler/worker/node counts, web server, networking) and flags outdated or non-LTS airflow versions and missing web server URIs.
- **DAG and scheduler health**: Flags failed DAG runs, failing task instances, and a non-operational scheduler.
- **Worker and queue health**: Flags queue backlogs (queued vs running tasks) and under/over-provisioned workers.
- **Error logs**: Scans Cloud Logging for `ERROR`+ entries per environment over a configurable lookback window.
- **Health summary**: Aggregates the above into a normalized summary table with next-steps per environment.

## SLI

The SLI (`sli.robot`) produces a 0–1 health score by averaging five binary sub-scores (each also pushed as a sub-metric with its raw issue count):

- **Environment state** — no environments outside `RUNNING`
- **Configuration health** — no outdated/misconfigured environments
- **DAG/scheduler health** — no failed DAG runs, failing tasks, or scheduler issues
- **Worker/queue health** — no queue backlogs or worker provisioning issues
- **Error logs** — no `ERROR`+ environment log entries

## Configuration

### Required Variables

- `GCP_PROJECT_ID`: The GCP project ID that contains the Cloud Composer environments.

### Optional Variables

- `ENV_NAME`: Pin monitoring to a single Composer environment name; defaults to `All` (auto-discover all environments in the project). (default: `All`)
- `LOG_LOOKBACK_WINDOW_DAYS`: Number of days back to scan Cloud Logging for error entries. (default: `14`)
- `STALE_QUEUE_AGE_MINUTES`: Age in minutes after which a queued task instance is considered stale/backlogged. (default: `60`)

### Secrets

- `gcp_credentials`: GCP service account JSON used to authenticate with GCP APIs and the `gcloud` CLI. Format: a JSON object with `type: service_account`, `project_id`, `client_email`, and `private_key`.

## Tasks Overview

### Check Cloud Composer Environment Health State in GCP Project
Lists all Cloud Composer environments in the project and flags any that are not in a healthy `RUNNING` state (`ERROR`, `CREATING`, `UPDATING`, `DELETING`, or degraded).

### Fetch Cloud Composer Environment Configurations in GCP Project
Dumps full environment configuration (airflow version, software config, scheduler/worker/node counts, web server, image version, networking) and flags missing or misconfigured settings, including environments using outdated or non-LTS airflow versions.

### Check Cloud Composer DAG and Scheduler Health in GCP Project
Checks live job states: failed DAG runs, failing task instances, DAG list risks, and scheduler jobs; flags broken DAGs or a non-operational scheduler.

### Check Cloud Composer Worker and Queue Health in GCP Project
Checks Airflow queue and worker states: size of the task-instance queue, tasks queued vs running, and worker provisioning; flags queue backlogs or under/over-provisioned workers.

### Get Error Logs for Cloud Composer Environments in GCP Project
Scans Cloud Logging (`resource.type=cloud_composer_environment`) for `ERROR` and higher severity entries over the lookback window and groups them per environment, surfacing the most common failures.

### Generate Cloud Composer Health Summary for GCP Project
Aggregates environment state, job health, worker/queue health, and error-log findings into a normalized summary table and next-steps for each environment in the project.

## Requirements

Cloud Composer is managed Airflow. Live job/queue state is obtained through the Airflow REST API / `gcloud composer environments run` (Airflow CLI) commands, which require Airflow RBAC roles on top of the basic Composer viewer permissions. Environment state and configuration come from the Composer API and do not need Airflow-level access.

The service account should have, at minimum:

- `composer.environments.get`
- `composer.environments.list`
- `composer.environments.run`
- `logging.logEntries.list`

Plus the Airflow viewer/operator roles required by the selected Airflow connection. Keep the task set within the execution budget by gating Airflow CLI calls to the discovered environment list (`ENV_NAME` can pin a single environment for debugging).
