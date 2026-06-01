---
name: terraform-cloud-workspace-lock-check
kind: skill-template
description: Check whether the Terraform Cloud Workspace is in a locked state. Use when triaging or monitoring Terraform, Cloud workloads with skill template `terraform-cloud-workspace-lock-check`.
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [Terraform, Cloud]
resource_types: []
access: read-only
---

# Terraform Cloud Workspace Lock Check

## Summary

Check whether the Terraform Cloud Workspace is in a locked state.

See [README.md](README.md) for additional context.

## Tools

### Checking whether the Terraform Cloud Workspace '${TERRAFORM_WORKSPACE_NAME}' is in a locked state

Use curl to check whether the Terraform Cloud Workspace is in a locked state

- **Robot task name**: <code>Checking whether the Terraform Cloud Workspace '${TERRAFORM_WORKSPACE_NAME}' is in a locked state</code>
- **Robot file**: `runbook.robot`
- **Tags**: `access:read-only`, `terraform`, `cloud`, `workspace`, `lock`, `data:config`
- **Reads**: `TERRAFORM_API_TOKEN`, `TERRAFORM_API_URL`, `TERRAFORM_ORGANIZATION_NAME`, `TERRAFORM_WORKSPACE_NAME`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `TERRAFORM_API_URL` | string | What URL to perform requests against. | `https://app.terraform.io/api/v2` | no |
| `TERRAFORM_ORGANIZATION_NAME` | string | Name of the organization in Terraform Cloud. | `` | yes |
| `TERRAFORM_WORKSPACE_NAME` | string | Name of the workspace in Terraform Cloud. | `` | yes |

## Secrets

| Name | Description | Required |
|---|---|---|
| `TERRAFORM_API_TOKEN` | Bearer Token to use for authentication to Terraform Cloud API | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/terraform-cloud-workspace-lock-check/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/terraform-cloud-workspace-lock-check
export TERRAFORM_API_URL=...
export TERRAFORM_ORGANIZATION_NAME=...
export TERRAFORM_WORKSPACE_NAME=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
