---
name: gcp-apigee-product-governance
kind: skill-template
description: Governs the consumer-side entitlement layer of an Apigee X organization: API products, developer apps and their... Use when triaging or monitoring GCP, Apigee, Products workloads with skill templat...
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Apigee, Products, Developers, Apps, Governance]
resource_types: [gcp_resource]
access: read-only
---

# GCP Apigee Product and Developer Governance

## Summary

Governs the consumer-side entitlement layer of an Apigee X organization: API products, developer apps and their consumer keys/credentials, developer status,.

See [README.md](README.md) for additional context.

## Tools

### Check Apigee API Product Expiry and Status in `${APIGEE_ORG}`

Flags API products that permit auto-approval (unapproved access) or that have missing/zero quota or rate limits, which weaken access control or break intended limits.

- **Robot task name**: <code>Check Apigee API Product Expiry and Status in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_api_products.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `security`, `access:read-only`, `data:config`
- **Reads**: `APIGEE_ORG`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Developer App Credential Expiry in `${APIGEE_ORG}`

Verifies each developer-app consumer key is not expired or expiring within KEY_EXPIRY_WARNING_DAYS, flagging credentials that will silently return 401s to consumers.

- **Robot task name**: <code>Check Apigee Developer App Credential Expiry in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_app_credentials.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:config`
- **Reads**: `APIGEE_ORG`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Orphaned and Unused Products and Apps in `${APIGEE_ORG}`

Identifies API products with no developer app attached, developer apps with no consumer keys, and entitlements that see no traffic over the lookback window, for housekeeping.

- **Robot task name**: <code>Check Apigee Orphaned and Unused Products and Apps in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_orphaned_entitlements.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:config`
- **Reads**: `APIGEE_ORG`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Check Apigee Developer Status and Dangling References in `${APIGEE_ORG}`

Flags developers that are inactive/blocked while their apps remain active, and apps whose credentials reference API products that no longer exist (dangling references).

- **Robot task name**: <code>Check Apigee Developer Status and Dangling References in `${APIGEE_ORG}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check_developer_status.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:state`
- **Reads**: `APIGEE_ORG`
- **Writes**: —
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


## Monitor

Scores Apigee product/developer governance health as a value between 0 and 1 by averaging per-dimension binary checks (product access-control and quota, credential expiry, orphaned entitlements, developer status). A dimension whose underlying Apigee API calls could not be read scores 0, never 1 -- an unreadable organization must not look healthy.

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the sub-checks below
- **Recommended interval**: `180s`

### Sub-checks

#### Score Apigee API Product Governance in `${APIGEE_ORG}`

Scores 1 if no API product permits auto-approval or has a missing/zero quota, 0 otherwise. Scores 0 if the API products could not be listed.

- **Robot task name**: <code>Score Apigee API Product Governance in `${APIGEE_ORG}`</code>
- **Sub-metric name**: `product_issue_count`
- **Underlying script**: `check_api_products.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `security`, `access:read-only`, `data:config`
- **Reads**: `APIGEE_ORG`


#### Score Apigee Consumer-Key Expiry in `${APIGEE_ORG}`

Scores 1 if no developer-app consumer key is expired or expiring within the warning window, 0 otherwise. Scores 0 if the developer apps could not be listed.

- **Robot task name**: <code>Score Apigee Consumer-Key Expiry in `${APIGEE_ORG}`</code>
- **Sub-metric name**: `expiring_key_count`
- **Underlying script**: `check_app_credentials.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:config`
- **Reads**: `APIGEE_ORG`


#### Score Apigee Orphaned/Unused Entitlements in `${APIGEE_ORG}`

Scores 1 if there are no orphaned API products, apps without consumer keys, or unused apps, 0 otherwise. Scores 0 if the entitlement surface could not be listed.

- **Robot task name**: <code>Score Apigee Orphaned/Unused Entitlements in `${APIGEE_ORG}`</code>
- **Sub-metric name**: `orphaned_issue_count`
- **Underlying script**: `check_orphaned_entitlements.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:config`
- **Reads**: `APIGEE_ORG`


#### Score Apigee Developer Status in `${APIGEE_ORG}`

Scores 1 if no developer is inactive/blocked with active apps and no app references a missing API product, 0 otherwise. Scores 0 if the developers could not be listed.

- **Robot task name**: <code>Score Apigee Developer Status in `${APIGEE_ORG}`</code>
- **Sub-metric name**: `developer_issue_count`
- **Underlying script**: `check_developer_status.sh`
- **Tags**: `gcloud`, `apigee`, `gcp`, `${APIGEE_ORG}`, `access:read-only`, `data:state`
- **Reads**: `APIGEE_ORG`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | The GCP project that owns the Apigee organization. | — | yes |
| `APIGEE_ORG` | string | The Apigee organization name. If empty, it is resolved from GCP_PROJECT_ID. | `${EMPTY}` | no |
| `APIPRODUCTS` | string | Comma-separated API product names to scope the analysis, or 'All'. | `All` | no |
| `DEVELOPER_APPS` | string | Comma-separated developer app names to scope the analysis, or 'All'. | `All` | no |
| `KEY_EXPIRY_WARNING_DAYS` | string | Days before a developer-app consumer key expires to raise a warning (severity 3). | `30` | no |
| `USAGE_LOOKBACK_DAYS` | string | Lookback window in days for the Analytics developer_app usage cross-reference. | `30` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON key used to authenticate with gcloud and the Apigee management REST API. | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-apigee-product-governance/runbook.robot`
- **Monitor**: `codebundles/gcp-apigee-product-governance/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-apigee-product-governance
export GCP_PROJECT_ID=...
export APIGEE_ORG=...
export APIPRODUCTS=...
export DEVELOPER_APPS=...
export KEY_EXPIRY_WARNING_DAYS=...
ro runbook.robot
```

### Standalone scripts (no Robot)


Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-apigee-product-governance
export GCP_PROJECT_ID=...
export APIGEE_ORG=...
export APIPRODUCTS=...
bash apigee_common.sh
bash check_api_products.sh
bash check_app_credentials.sh
bash check_developer_status.sh
bash check_orphaned_entitlements.sh
bash discover_entitlements.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `apigee_common.sh` — Bash helper script `apigee_common.sh`.
- `check_api_products.sh` — Bash helper script `check_api_products.sh`.
- `check_app_credentials.sh` — Bash helper script `check_app_credentials.sh`.
- `check_developer_status.sh` — Bash helper script `check_developer_status.sh`.
- `check_orphaned_entitlements.sh` — Bash helper script `check_orphaned_entitlements.sh`.
- `discover_entitlements.sh` — Bash helper script `discover_entitlements.sh`.
