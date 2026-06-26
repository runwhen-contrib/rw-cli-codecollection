---
name: aws-cloudwatch-overused-ec2
kind: skill-template
description: Queries AWS CloudWatch for a list of EC2 instances with a high amount of resource utilization, raising issues when... Use when triaging or monitoring AWS, CloudWatch workloads with skill template `...
runtime:
  runbook: runbook.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [AWS, CloudWatch]
resource_types: [ec2_instance]
access: read-only
---

# AWS CloudWatch Overutlized EC2 Inspection

## Summary

This taskset can be used to check a fleet of EC2 instance and return the list of instances which are classified as overutilized.

See [README.md](README.md) for additional context.

## Tools

### Check For Overutilized Ec2 Instances

Fetches CloudWatch metrics for a list of EC2 instances and raises issues if they're over-utilized based on a configurable threshold.

- **Robot task name**: <code>Check For Overutilized Ec2 Instances</code>
- **Robot file**: `runbook.robot`
- **Tags**: `cloudwatch`, `metrics`, `ec2`, `utilization`, `data:config`
- **Reads**: `AWS_DEFAULT_REGION`, `UTILIZATION_THRESHOLD`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `AWS_DEFAULT_REGION` | string | The AWS region to scope API requests to. | `us-west-1` | no |
| `UTILIZATION_THRESHOLD` | string | The threshold at which an instance is determined as overutilized. | `0.8` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `aws_credentials` | AWS credentials from the workspace (from aws-auth block; e.g. aws:access_key@cli, aws:irsa@cli). | yes |

## Outputs

_See Robot run output and platform report artifacts._

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/aws-cloudwatch-overused-ec2/runbook.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/aws-cloudwatch-overused-ec2
export AWS_DEFAULT_REGION=...
export UTILIZATION_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


_No standalone shell scripts in this bundle._

## Source files

- `runbook.robot` — orchestrates tools and raises issues
