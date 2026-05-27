---
name: gcp-bucket-health
description: Inspect GCP Storage bucket usage and configuration. Use when triaging or monitoring GCP, GCS workloads with skill template `gcp-bucket-health`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  runner: ro
platforms: [GCP, GCS]
resource_types: [gcp_resource]
access: read-only
---

# GCP Storage Bucket Health

## Summary

This code checks if any GCP (Google Cloud Platform) buckets are unhealthy, focusing on: - Utilization  (with a user defined threshold for issue/alert generation).

See [README.md](README.md) for additional context.

## Tools

### Fetch GCP Bucket Storage Utilization for `${PROJECT_IDS}`

Fetches all GCP buckets in each project and obtains the total size.

- **Robot task name**: <code>Fetch GCP Bucket Storage Utilization for `${PROJECT_IDS}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `bucket_size.sh`
- **Tags**: `gcloud`, `gcs`, `gcp`, `bucket`, `data:config`
- **Reads**: `USAGE_THRESHOLD`
- **Writes**: `bucket_report.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Add GCP Bucket Storage Configuration for `${PROJECT_IDS}` to Report

Fetches all GCP buckets in each project and obtains the total size.

- **Robot task name**: <code>Add GCP Bucket Storage Configuration for `${PROJECT_IDS}` to Report</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `bucket_details.sh`
- **Tags**: `gcloud`, `gcs`, `gcp`, `bucket`, `data:config`
- **Reads**: —
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check GCP Bucket Security Configuration for `${PROJECT_IDS}`

Fetches all GCP buckets in each project and checks for public buckets, risky IAM permissions, and encryption configuration.

- **Robot task name**: <code>Check GCP Bucket Security Configuration for `${PROJECT_IDS}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_security.sh`
- **Tags**: `gcloud`, `gcs`, `gcp`, `bucket`, `security`, `data:config`
- **Reads**: `PUBLIC_ACCESS_BUCKET_THRESHOLD`
- **Writes**: `bucket_security_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Fetch GCP Bucket Storage Operations Rate for `${PROJECT_IDS}`

Fetches all GCP buckets in each project and obtains the read and write operations rate that incurrs cost. Generates issues if the rate is above a specified threshold.

- **Robot task name**: <code>Fetch GCP Bucket Storage Operations Rate for `${PROJECT_IDS}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `bucket_ops_costs.sh`
- **Tags**: `gcloud`, `gcs`, `gcp`, `bucket`, `data:config`
- **Reads**: `OPS_RATE_THRESHOLD`
- **Writes**: `bucket_ops_report.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

This SLI uses the GCP API or gcloud to score bucket health. Produces a value between 0 (completely failing thet test) and 1 (fully passing the test). Looks for usage above a threshold and public buckets.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Fetch GCP Bucket Storage Utilization for `${PROJECT_IDS}`

Fetches all GCP buckets in each project and obtains the total size.

- **Robot task name**: <code>Fetch GCP Bucket Storage Utilization for `${PROJECT_IDS}`</code>
- **Sub-metric name**: `storage_utilization`
- **Underlying script**: `bucket_size.sh`
- **Tags**: `gcloud`, `gcs`, `gcp`, `bucket`, `data:config`
- **Reads**: `USAGE_THRESHOLD`
- **Pass condition**: `int(${buckets_over_threshold.stdout}) == 0`


#### Check GCP Bucket Security Configuration for `${PROJECT_IDS}`

Fetches all GCP buckets in each project and checks for public buckets, risky IAM permissions, and encryption configuration.

- **Robot task name**: <code>Check GCP Bucket Security Configuration for `${PROJECT_IDS}`</code>
- **Sub-metric name**: `security_config`
- **Underlying script**: `check_security.sh`
- **Tags**: `gcloud`, `gcs`, `gcp`, `bucket`, `security`, `data:config`
- **Reads**: `PUBLIC_ACCESS_BUCKET_THRESHOLD`
- **Pass condition**: `int(${total_public_access_buckets.stdout}) <= ${PUBLIC_ACCESS_BUCKET_THRESHOLD}`


#### Fetch GCP Bucket Storage Operations Rate for `${PROJECT_IDS}`

Fetches all GCP buckets in each project and obtains the read and write operations rate that incurrs cost.

- **Robot task name**: <code>Fetch GCP Bucket Storage Operations Rate for `${PROJECT_IDS}`</code>
- **Sub-metric name**: `operations_rate`
- **Underlying script**: `bucket_ops_costs.sh`
- **Tags**: `gcloud`, `gcs`, `gcp`, `bucket`, `data:config`
- **Reads**: `OPS_RATE_THRESHOLD`
- **Pass condition**: `int(${buckets_over_ops_threshold.stdout}) == 0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `PROJECT_IDS` | string | The GCP Project ID to scope the API to. Accepts multiple comma separated project IDs. | — | yes |
| `USAGE_THRESHOLD` | string | The amount of storage, in TB, to generate an issue on. | `0.5` | no |
| `OPS_RATE_THRESHOLD` | string | The rate of read+write operations, in ops/s, to generate an issue on. | `10` | no |
| `PUBLIC_ACCESS_BUCKET_THRESHOLD` | string | The amount of storage buckets that can be publicly accessible. | `0` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account json used to authenticate with GCP APIs. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`
- `bucket_report.json`
- `bucket_security_issues.json`
- `bucket_ops_report.json`

## How to invoke

### Preferred: Robot Framework runner (`ro`)

```bash
cd codebundles/gcp-bucket-health
export PROJECT_IDS=...
export USAGE_THRESHOLD=...
export OPS_RATE_THRESHOLD=...
export PUBLIC_ACCESS_BUCKET_THRESHOLD=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-bucket-health
export PROJECT_IDS=...
export USAGE_THRESHOLD=...
export OPS_RATE_THRESHOLD=...
bash bucket_details.sh
bash bucket_ops_costs.sh
bash bucket_size.sh
bash check_security.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `bucket_details.sh` — Bash helper script `bucket_details.sh`.
- `bucket_ops_costs.sh` — Bash helper script `bucket_ops_costs.sh`.
- `bucket_size.sh` — Bash helper script `bucket_size.sh`.
- `check_security.sh` — Bash helper script `check_security.sh`.
