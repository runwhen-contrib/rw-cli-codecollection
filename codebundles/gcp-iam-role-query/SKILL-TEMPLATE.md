---
name: gcp-iam-role-query
kind: skill-template
description: On-demand query tool for GCP IAM that reports role bindings for service accounts, resources, and services. Use when auditing or triaging GCP IAM access with skill template `gcp-iam-role-query`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, IAM]
resource_types: [gcp_iam_policy]
access: read-only
---

# GCP IAM Role Query

## Summary

This codebundle is a generic, on-demand query tool for GCP IAM. It answers "what roles are assigned to this service account?" and "what roles are granted on this specific GCP service or resource?" using runtime variables, so operators can fetch role and access information dynamically without new bundles.

See [README.md](README.md) for additional context.

## Tools

### Query IAM Roles for Service Account in Project `${GCP_PROJECT_ID}`

Returns the full set of IAM role bindings attached to a specific service account, including inherited project and resource bindings.

- **Robot task name**: <code>Query IAM Roles for Service Account in Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `query_service_account_roles.sh`
- **Tags**: `gcp`, `iam`, `serviceaccount`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `SERVICE_ACCOUNT`
- **Writes**: `service_account_role_issues.json`
- **Issues raised**: informational when the service account or its policy cannot be resolved

### Query IAM Roles Assigned to Resource in Project `${GCP_PROJECT_ID}`

Returns the IAM policy and role bindings for a user-supplied GCP resource using a typed resource string.

- **Robot task name**: <code>Query IAM Roles Assigned to Resource in Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `query_resource_roles.sh`
- **Tags**: `gcp`, `iam`, `resource`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `RESOURCE_NAME`, `SERVICE_TYPE`
- **Writes**: `resource_role_issues.json`
- **Issues raised**: informational when the resource or its policy cannot be resolved

### List IAM Roles for GCP Service in Project `${GCP_PROJECT_ID}`

Queries the IAM bindings on a named GCP service type across the project, filtering by the requested resource kind.

- **Robot task name**: <code>List IAM Roles for GCP Service in Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `query_service_roles.sh`
- **Tags**: `gcp`, `iam`, `service`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`, `SERVICE_TYPE`, `RESOURCE_NAME`
- **Writes**: `service_role_issues.json`
- **Issues raised**: informational when resources cannot be listed or a policy is not retrievable

### Generate IAM Policy Report for Project `${GCP_PROJECT_ID}`

Produces a consolidated report of all IAM bindings in the project grouped by principal and role for on-demand auditing.

- **Robot task name**: <code>Generate IAM Policy Report for Project `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `generate_policy_report.sh`
- **Tags**: `gcp`, `iam`, `policy`, `report`, `data:config`, `access:read-only`
- **Reads**: `GCP_PROJECT_ID`
- **Writes**: `policy_report_issues.json`, `project_iam_policy.json`, `policy_report_summary.json`
- **Issues raised**: informational when the project IAM policy cannot be retrieved


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP Project ID that provides the IAM context for queries. | — | yes |
| `SERVICE_ACCOUNT` | string | Service account email to query role bindings for. | `` | no |
| `RESOURCE_NAME` | string | Full or short name of the GCP resource to query IAM for. | `` | no |
| `SERVICE_TYPE` | string | GCP service type (e.g. storage, bigquery, run) used to scope the query. | `` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with Cloud IAM APIs. | yes |

## Outputs

- `service_account_role_issues.json`
- `resource_role_issues.json`
- `service_role_issues.json`
- `policy_report_issues.json`
- `project_iam_policy.json`
- `policy_report_summary.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker image (`rw-base-runtime`) executes Robot via `runrobot.sh` with `RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-iam-role-query/runbook.robot`

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-iam-role-query
export GCP_PROJECT_ID=...
export SERVICE_ACCOUNT=sa@project.iam.gserviceaccount.com
bash query_service_account_roles.sh
export RESOURCE_NAME=my-bucket
export SERVICE_TYPE=storage
bash query_resource_roles.sh
export SERVICE_TYPE=storage
export RESOURCE_NAME=All
bash query_service_roles.sh
bash generate_policy_report.sh
```

## Source files

- `runbook.robot` — orchestrates the query tools and raises issues
- `query_service_account_roles.sh` — queries role bindings for a service account
- `query_resource_roles.sh` — queries IAM policy for a specific resource
- `query_service_roles.sh` — lists roles across a GCP service type
- `generate_policy_report.sh` — produces a consolidated IAM policy report
