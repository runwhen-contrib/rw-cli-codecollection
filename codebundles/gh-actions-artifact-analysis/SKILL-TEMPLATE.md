---
name: gh-actions-artifact-analysis
kind: skill-template
description: This taskset fetches the latest GitHub Actions worflow run artifact and analyzes the results with a user provided... Use when triaging or monitoring GitHub, Actions workloads with skill template `g...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GitHub, Actions]
resource_types: []
access: read-only
---

# GitHub Actions Artifact Analysis

## Summary

This codebundle is highly configurable and integrates with GitHub Actions and workflow artifacts.

See [README.md](README.md) for additional context.

## Tools

### Analyze artifact from GitHub workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}`

Check GitHub workflow status and analyze artifact with a user provided command.

- **Robot task name**: <code>Analyze artifact from GitHub workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `gh_actions_artifact_analysis.sh`
- **Tags**: `github`, `workflow`, `actions`, `artifact`, `report`, `access:read-only`, `data:config`
- **Reads**: `ANALYSIS_COMMAND`, `GITHUB_REPO`, `GITHUB_TOKEN`, `ISSUE_NEXT_STEPS`, `ISSUE_SEARCH_STRING`, `ISSUE_SEVERITY`, `ISSUE_TITLE`, `WORKFLOW_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI fetches the latest GitHub Actions worflow run artifact pushes a metric based on a user provided command.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Analyze artifact from GitHub Workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}` and push metric

Check GitHub workflow status, run a user provided analysis command, and push the metric. The analysis command should result in a single metric.

- **Robot task name**: <code>Analyze artifact from GitHub Workflow `${WORKFLOW_NAME}` in repository `${GITHUB_REPO}` and push metric</code>
- **Sub-metric name**: `artifact_analysis`
- **Underlying script**: `gh_actions_artifact_analysis.sh`
- **Tags**: `github`, `workflow`, `actions`, `artifact`, `report`, `data:config`
- **Reads**: `ANALYSIS_COMMAND`, `GITHUB_TOKEN`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GITHUB_REPO` | string | The GitHub Reposiroty to query | `''` | no |
| `WORKFLOW_NAME` | string | The GitHub Actions workflow name. | `''` | no |
| `ARTIFACT_NAME` | string | The artifact to inspect. | `''` | no |
| `ANALYSIS_COMMAND` | string | A command to run against the output report. Tools like jq and awk are available. | `''` | no |
| `RESULT_FILE` | string | The artifact to inspect. | `''` | no |
| `PERIOD_HOURS` | string | The amount of hours to condider for a healthy last workflow run. | `24` | no |
| `ISSUE_SEARCH_STRING` | string | A string that, if found in the analysis output, will generate an Issue. | `ERROR|Error` | no |
| `ISSUE_SEVERITY` | string | The severity of the issue. 1 = Critical, 2=Major, 3=Minor, 4=Informational | `4` | no |
| `ISSUE_TITLE` | string | The title of the issue. | `The text `${ISSUE_SEARCH_STRING}` was found in GitHub Workflow `${WORKFLOW_NAME}` in repo `${GITHUB_REPO}`` | no |
| `ISSUE_NEXT_STEPS` | string | A list of next steps to take when the Issue is raised. Use `\n` to separate items in the list.' | `Review the log output or escalate to the service owner.` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `GITHUB_TOKEN` | The GitHub Token used to access the repository. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gh-actions-artifact-analysis/runbook.robot`
- **Monitor**: `codebundles/gh-actions-artifact-analysis/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gh-actions-artifact-analysis
export GITHUB_REPO=...
export WORKFLOW_NAME=...
export ARTIFACT_NAME=...
export ANALYSIS_COMMAND=...
export RESULT_FILE=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gh-actions-artifact-analysis
export GITHUB_REPO=...
export WORKFLOW_NAME=...
export ARTIFACT_NAME=...
export ANALYSIS_COMMAND=...
bash gh_actions_artifact_analysis.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `gh_actions_artifact_analysis.sh` — Bash helper script `gh_actions_artifact_analysis.sh`.
