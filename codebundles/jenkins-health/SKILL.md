---
name: jenkins-health
description: List Jenkins health, failed builds, tests and long running builds. Use when triaging or monitoring Jenkins workloads with skill template `jenkins-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [Jenkins]
resource_types: []
access: read-only
---

# Jenkins Health

## Summary

This CodeBundle monitors and evaluates the health of Jenkins using the Jenkins REST API The SLI produces a score of 0 (bad), 1(good), or a value in between.

See [README.md](README.md) for additional context.

## Tools

### List Failed Build Logs in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Fetches logs from failed Jenkins builds using the Jenkins API

- **Robot task name**: <code>List Failed Build Logs in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `${CURDIR}/failed_build_logs.sh`
- **Tags**: `Jenkins`, `Logs`, `Builds`, `data:logs-regexp`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_USERNAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Long Running Builds in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Identifies Jenkins builds that have been running longer than a specified threshold

- **Robot task name**: <code>List Long Running Builds in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `${CURDIR}/long_running_builds.sh`
- **Tags**: `Jenkins`, `Builds`, `data:config`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_USERNAME`, `LONG_RUNNING_BUILD_MAX_WAIT_TIME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Recent Failed Tests in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

List Recent Failed Tests in Jenkins Instance

- **Robot task name**: <code>List Recent Failed Tests in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Jenkins`, `Tests`, `data:logs-regexp`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Jenkins Instance `${JENKINS_INSTANCE_NAME}` Health

Check if Jenkins instance is reachable and responding

- **Robot task name**: <code>Check Jenkins Instance `${JENKINS_INSTANCE_NAME}` Health</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Jenkins`, `Health`, `data:config`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Long Queued Builds in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Check for builds stuck in queue beyond threshold

- **Robot task name**: <code>List Long Queued Builds in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Jenkins`, `Queue`, `Builds`, `data:config`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`, `QUEUED_BUILD_MAX_WAIT_TIME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### List Executor Utilization in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Check Jenkins executor utilization across nodes

- **Robot task name**: <code>List Executor Utilization in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Jenkins`, `Executors`, `Utilization`, `data:config`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`, `MAX_EXECUTOR_UTILIZATION`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch Jenkins Instance `${JENKINS_INSTANCE_NAME}` Logs and Add to Report

Fetches and displays Jenkins logs from the Atom feed

- **Robot task name**: <code>Fetch Jenkins Instance `${JENKINS_INSTANCE_NAME}` Logs and Add to Report</code>
- **Robot file**: `runbook.robot`
- **Tags**: `Jenkins`, `Logs`, `data:logs-bulk`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Check Jenkins health, failed builds, tests and long running builds

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Check For Failed Build Logs in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Check For Failed Build Logs in Jenkins

- **Robot task name**: <code>Check For Failed Build Logs in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Sub-metric name**: `failed_builds`
- **Underlying script**: `${CURDIR}/failed_build_logs.sh`
- **Tags**: `Jenkins`, `Logs`, `Builds`, `data:logs-regexp`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_USERNAME`, `MAX_FAILED_BUILDS`
- **Pass condition**: `int(${failed_builds}) <= int(${MAX_FAILED_BUILDS})`


#### Check For Long Running Builds in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Check Jenkins builds that have been running longer than a specified threshold

- **Robot task name**: <code>Check For Long Running Builds in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Sub-metric name**: `long_running_builds`
- **Underlying script**: `${CURDIR}/long_running_builds.sh`
- **Tags**: `Jenkins`, `Builds`, `data:config`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_USERNAME`, `LONG_RUNNING_BUILD_MAX_WAIT_TIME`, `MAX_LONG_RUNNING_BUILDS`
- **Pass condition**: `int(${long_running_count}) <= int(${MAX_LONG_RUNNING_BUILDS})`


#### Check For Recent Failed Tests in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Check For Recent Failed Tests in Jenkins

- **Robot task name**: <code>Check For Recent Failed Tests in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Sub-metric name**: `failed_tests`
- **Tags**: `Jenkins`, `Tests`, `data:logs-regexp`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`, `MAX_ALLOWED_FAILED_TESTS`
- **Pass condition**: `int(${total_failed_tests}) <= int(${MAX_ALLOWED_FAILED_TESTS})`


#### Check For Jenkins Instance `${JENKINS_INSTANCE_NAME}` Health

Check if Jenkins instance is reachable and responding

- **Robot task name**: <code>Check For Jenkins Instance `${JENKINS_INSTANCE_NAME}` Health</code>
- **Sub-metric name**: `instance_health`
- **Tags**: `Jenkins`, `Health`, `data:config`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`


#### Check For Long Queued Builds in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Check for builds stuck in queue beyond threshold and calculate SLI score

- **Robot task name**: <code>Check For Long Queued Builds in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Sub-metric name**: `queued_builds`
- **Tags**: `Jenkins`, `Queue`, `Builds`, `SLI`, `data:config`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`, `MAX_QUEUED_BUILDS`, `QUEUED_BUILD_MAX_WAIT_TIME`
- **Pass condition**: `int(${queued_count}) <= int(${MAX_QUEUED_BUILDS})`


#### Check Jenkins Executor Utilization in Jenkins Instance `${JENKINS_INSTANCE_NAME}`

Check if Jenkins executor utilization is above 80%

- **Robot task name**: <code>Check Jenkins Executor Utilization in Jenkins Instance `${JENKINS_INSTANCE_NAME}`</code>
- **Sub-metric name**: `executor_utilization`
- **Tags**: `Jenkins`, `Executors`, `Utilization`, `data:config`
- **Reads**: `JENKINS_TOKEN`, `JENKINS_URL`, `JENKINS_USERNAME`, `MAX_EXECUTOR_UTILIZATION`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `JENKINS_URL` | string | The URL of your Jenkins instance | — | yes |
| `LONG_RUNNING_BUILD_MAX_WAIT_TIME` | string | The threshold for long running builds, formats like '5m', '2h', '1d' or '5min', '2h', '1d' | `"10m"` | no |
| `QUEUED_BUILD_MAX_WAIT_TIME` | string | The time threshold for builds in queue, formats like '5m', '2h', '1d' or '5min', '2h', '1d' | `"10m"` | no |
| `MAX_EXECUTOR_UTILIZATION` | string | The maximum percentage of executor utilization to consider healthy | `"80"` | no |
| `JENKINS_INSTANCE_NAME` | string | Jenkins Instance Name | `"prod-jenkins"` | no |
| `MAX_LONG_RUNNING_BUILDS` | string | The maximum number of long running builds to consider healthy | `"0"` | no |
| `MAX_FAILED_BUILDS` | string | The maximum number of failed builds allowed and consider healthy | `"0"` | no |
| `MAX_ALLOWED_FAILED_TESTS` | string | The maximum number of failed tests allowed and consider healthy | `"0"` | no |
| `MAX_QUEUED_BUILDS` | string | The maximum number of builds stuck in queue to consider healthy | `"0"` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `JENKINS_USERNAME` | Jenkins username for authentication | yes |
| `JENKINS_TOKEN` | Jenkins API token for authentication | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/jenkins-health
export JENKINS_URL=...
export LONG_RUNNING_BUILD_MAX_WAIT_TIME=...
export QUEUED_BUILD_MAX_WAIT_TIME=...
export MAX_EXECUTOR_UTILIZATION=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/jenkins-health
export JENKINS_URL=...
export LONG_RUNNING_BUILD_MAX_WAIT_TIME=...
bash failed_build_logs.sh
bash long_running_builds.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `failed_build_logs.sh` — Bash helper script `failed_build_logs.sh`.
- `long_running_builds.sh` — Bash helper script `long_running_builds.sh`.
