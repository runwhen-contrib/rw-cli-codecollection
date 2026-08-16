---
name: gcp-iam-serviceaccount-health
kind: skill-template
description: Inspect GCP IAM service accounts for privileged role assignments, key hygiene, disabled accounts in use, and IAM policy drift. Use when triaging or monitoring GCP IAM serviceaccounts with skill template `gcp-iam-serviceaccount-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, IAM, ServiceAccount]
resource_types: [gcp_resource]
access: read-only
---

# GCP IAM Service Account Health

## Summary

Monitors GCP IAM service accounts to detect risk from excessive or privileged role assignments, improper key hygiene (old, many, or un-rotated keys), disabled service accounts still bound to resources, and overly broad IAM bindings across a project.

See [README.md](README.md) for additional context.

## Tools

### Check Service Account Privileged Role Assignments for `${GCP_PROJECT_ID}`

Lists service accounts granted owner, editor, or other high-privilege roles (configured via `PRIVILEGED_ROLES`) at the project or service-account level. Raises issues for each privileged binding found.

- **Robot task name**: <code>Check Service Account Privileged Role Assignments for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_privileged_roles.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `PRIVILEGED_ROLES`, `SERVICE_ACCOUNT`
- **Writes**: `privileged_roles_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Service Account Key Rotation for `${GCP_PROJECT_ID}`

Detects USER_MANAGED service account keys older than `KEY_ROTATION_DAYS` and warns when rotation is overdue. Raises a warning for stale keys and a higher-severity issue for keys more than twice the rotation threshold.

- **Robot task name**: <code>Check Service Account Key Rotation for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_key_rotation.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `KEY_ROTATION_DAYS`, `SERVICE_ACCOUNT`
- **Writes**: `key_rotation_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Service Accounts with Excessive Keys for `${GCP_PROJECT_ID}`

Flags service accounts holding more than `MAX_KEYS_PER_SA` active USER_MANAGED keys. Each extra key increases the attack surface and complicates rotation.

- **Robot task name**: <code>Identify Service Accounts with Excessive Keys for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_key_count.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `MAX_KEYS_PER_SA`, `SERVICE_ACCOUNT`
- **Writes**: `key_count_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Disabled Service Accounts in Use for `${GCP_PROJECT_ID}`

Finds disabled service accounts that are still referenced in project-level or service-account-level IAM policy bindings, which can indicate drift.

- **Robot task name**: <code>Identify Disabled Service Accounts in Use for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_disabled_service_accounts.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `SERVICE_ACCOUNT`
- **Writes**: `disabled_sa_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Analyze Service Account IAM Policy for Project `${GCP_PROJECT_ID}`

Summarizes all service-account-level IAM role bindings in the project for a quick health overview and drift detection (e.g., unused service accounts with no bindings).

- **Robot task name**: <code>Analyze Service Account IAM Policy for Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `analyze_service_account_policy.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `SERVICE_ACCOUNT`
- **Writes**: `policy_analysis_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI produces a 0-1 health score by averaging five binary dimensions: privileged role assignments, key rotation, key count, disabled service accounts, and IAM policy health.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of five sub-checks
- **Recommended interval**: `180s`

### Sub-checks

#### Score Service Account Privileged Role Assignments for `${GCP_PROJECT_ID}`

Scores privileged role assignments. Returns 1 if no service accounts hold high-privilege roles, 0 otherwise.

- **Robot task name**: <code>Score Service Account Privileged Role Assignments for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `privileged_roles`
- **Underlying script**: `check_privileged_roles.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `PRIVILEGED_ROLES`, `SERVICE_ACCOUNT`
- **Pass condition**: `int(${issue_count.stdout}) == 0`


#### Score Service Account Key Rotation for `${GCP_PROJECT_ID}`

Scores key rotation. Returns 1 if no keys exceed the rotation threshold, 0 otherwise.

- **Robot task name**: <code>Score Service Account Key Rotation for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `key_rotation`
- **Underlying script**: `check_key_rotation.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `KEY_ROTATION_DAYS`, `SERVICE_ACCOUNT`
- **Pass condition**: `int(${issue_count.stdout}) == 0`


#### Score Service Account Key Count for `${GCP_PROJECT_ID}`

Scores key count hygiene. Returns 1 if no service accounts exceed the maximum key count, 0 otherwise.

- **Robot task name**: <code>Score Service Account Key Count for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `key_count`
- **Underlying script**: `check_key_count.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `MAX_KEYS_PER_SA`, `SERVICE_ACCOUNT`
- **Pass condition**: `int(${issue_count.stdout}) == 0`


#### Score Disabled Service Accounts in Use for `${GCP_PROJECT_ID}`

Scores disabled service account hygiene. Returns 1 if no disabled service accounts are still referenced in IAM policies.

- **Robot task name**: <code>Score Disabled Service Accounts in Use for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `disabled_sa`
- **Underlying script**: `check_disabled_service_accounts.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `SERVICE_ACCOUNT`
- **Pass condition**: `int(${issue_count.stdout}) == 0`


#### Score Service Account IAM Policy Health for `${GCP_PROJECT_ID}`

Scores service account IAM policy health. Returns 1 if no drift (unused) service accounts are found in the policy analysis.

- **Robot task name**: <code>Score Service Account IAM Policy Health for `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `policy_health`
- **Underlying script**: `analyze_service_account_policy.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `security`, `data:config`
- **Reads**: `SERVICE_ACCOUNT`
- **Pass condition**: `int(${issue_count.stdout}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP Project ID that houses the service accounts to inspect. | — | yes |

## runtimeVarsProvided

All other variables are provided by the runtime with sensible defaults and do not need to be supplied by the user:

| Name | Type | Default | Validation | Description |
|---|---|---|---|---|
| `SERVICE_ACCOUNT` | string | `""` | regex `^[a-zA-Z0-9@.-]*$` | Optional email of a single service account to scope checks to. Empty means all service accounts in the project. |
| `KEY_ROTATION_DAYS` | string | `90` | regex `^\d+$` | Maximum allowed age of a service account key in days before rotation is flagged. |
| `MAX_KEYS_PER_SA` | string | `5` | regex `^\d+$` | Maximum allowed number of active keys per service account before it is flagged. |
| `PRIVILEGED_ROLES` | string | `roles/owner,roles/editor` | regex `^[a-zA-Z0-9/_,. -]+$` | Comma-separated list of roles considered high-privilege and worth flagging. |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `privileged_roles_issues.json`
- `key_rotation_issues.json`
- `key_count_issues.json`
- `disabled_sa_issues.json`
- `policy_analysis_issues.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-iam-serviceaccount-health/runbook.robot`
- **Monitor**: `codebundles/gcp-iam-serviceaccount-health/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-iam-serviceaccount-health
export GCP_PROJECT_ID=...
export SERVICE_ACCOUNT=...
export KEY_ROTATION_DAYS=...
export MAX_KEYS_PER_SA=...
export PRIVILEGED_ROLES=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-iam-serviceaccount-health
export GCP_PROJECT_ID=...
export SERVICE_ACCOUNT=...
export KEY_ROTATION_DAYS=...
export MAX_KEYS_PER_SA=...
export PRIVILEGED_ROLES=...
bash analyze_service_account_policy.sh
bash check_disabled_service_accounts.sh
bash check_key_count.sh
bash check_key_rotation.sh
bash check_privileged_roles.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `analyze_service_account_policy.sh` — Bash helper script `analyze_service_account_policy.sh`.
- `check_disabled_service_accounts.sh` — Bash helper script `check_disabled_service_accounts.sh`.
- `check_key_count.sh` — Bash helper script `check_key_count.sh`.
- `check_key_rotation.sh` — Bash helper script `check_key_rotation.sh`.
- `check_privileged_roles.sh` — Bash helper script `check_privileged_roles.sh`.