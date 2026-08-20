---
name: gcp-artifact-registry-governance
kind: skill-template
description: Inspect GCP Artifact Registry repositories for cleanup policy coverage, stale and untagged images, legacy GCR usage, and storage utilization. Use when triaging or monitoring GCP, Artifact Registry workloads with skill template `gcp-artifact-registry-governance`.
runtime:
  runbook: runbook.robot
  monitor: sli.robot
  executor: worker
  entrypoint: /home/runwhen/robot-runtime/runrobot.sh
  base_image: rw-base-runtime
platforms: [GCP, Artifact Registry]
resource_types: [gcp_artifactregistry_repositories]
access: read-only
---

# GCP Artifact Registry Governance

## Summary

Checks whether GCP Artifact Registry repositories are governed: cleanup policies are
configured and cover both untagged manifests and aged tags, stale and untagged images are
within thresholds, legacy Container Registry (`gcr.io`) usage has been migrated, and
storage utilization is within budget. All checks are read-only.

See [README.md](README.md) for additional context.

## Tools

### Check Cleanup Policy Configuration for Repositories in `${GCP_PROJECT_ID}`

Verifies Docker/OCI repositories have cleanup policies covering untagged manifests and aged tags.

- **Robot task name**: <code>Check Cleanup Policy Configuration for Repositories in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `check-cleanup-policies.sh`
- **Tags**: `gcp`, `artifact registry`, `cleanup policy`, `access:read-only`, `data:logs-config`
- **Reads**: `ARTIFACT_REGISTRY_LOCATIONS`, `ARTIFACT_REGISTRY_REPOSITORIES`
- **Writes**: `cleanup_policy_issues.json`
- **Issues raised**: Sev-2 when a Docker repository has no cleanup policies; Sev-3 when the untagged or aged-tag rule is missing; Sev-4 when dry-run is left enabled


### Identify Stale Container Images in `${GCP_PROJECT_ID}`

Finds tagged images that have not been updated or pulled within the configured threshold.

- **Robot task name**: <code>Identify Stale Container Images in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `identify-stale-images.sh`
- **Tags**: `gcp`, `artifact registry`, `stale images`, `access:read-only`, `data:logs-config`
- **Reads**: `STALE_IMAGE_THRESHOLD_DAYS`
- **Writes**: `stale_images_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Identify Untagged Images Consuming Storage in `${GCP_PROJECT_ID}`

Finds untagged (dangling) manifests older than the configured threshold.

- **Robot task name**: <code>Identify Untagged Images Consuming Storage in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `identify-untagged-images.sh`
- **Tags**: `gcp`, `artifact registry`, `untagged images`, `access:read-only`, `data:logs-config`
- **Reads**: `UNTAGGED_IMAGE_THRESHOLD_DAYS`
- **Writes**: `untagged_images_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Detect Legacy Container Registry Usage in `${GCP_PROJECT_ID}`

Identifies remaining `gcr.io` Container Registry usage that should be migrated to Artifact Registry.

- **Robot task name**: <code>Detect Legacy Container Registry Usage in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `detect-legacy-gcr-usage.sh`
- **Tags**: `gcp`, `artifact registry`, `legacy gcr`, `access:read-only`, `data:logs-config`
- **Reads**: —
- **Writes**: `legacy_gcr_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Report Artifact Registry Storage Utilization by Repository in `${GCP_PROJECT_ID}`

Reports estimated storage per repository and flags repositories above the configured threshold.

- **Robot task name**: <code>Report Artifact Registry Storage Utilization by Repository in `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `report-repository-storage-utilization.sh`
- **Tags**: `gcp`, `artifact registry`, `storage`, `access:read-only`, `data:logs-config`
- **Reads**: `STORAGE_UTILIZATION_THRESHOLD_GB`
- **Writes**: `storage_utilization_report.json`, `storage_utilization_issues.json`
- **Issues raised**: issues reported via `RW.Core.Add Issue` when checks fail


### Generate Artifact Registry Cleanup Policy Recommendations for `${GCP_PROJECT_ID}`

Generates read-only suggested cleanup policies and the gcloud command to apply them.

- **Robot task name**: <code>Generate Artifact Registry Cleanup Policy Recommendations for `${GCP_PROJECT_ID}`</code>
- **Robot file**: `runbook.robot`
- **Underlying script**: `generate-cleanup-policy-recommendations.sh`
- **Tags**: `gcp`, `artifact registry`, `recommendations`, `access:read-only`, `data:logs-config`
- **Reads**: `MIN_TAGS_TO_KEEP`, `STALE_IMAGE_THRESHOLD_DAYS`, `UNTAGGED_IMAGE_THRESHOLD_DAYS`
- **Writes**: `cleanup_policy_recommendations.json`
- **Issues raised**: Sev-4 informational issue per repository with a suggested policy


## Monitor

Measures Artifact Registry governance health by scoring cleanup policies, stale images,
untagged manifests, and storage utilization. Produces a value between 0 (failing) and 1
(fully passing).

- **Robot file**: `sli.robot`
- **Score range**: `0.0` (failing) to `1.0` (healthy)
- **Aggregation**: arithmetic mean of the four sub-checks below
- **Recommended interval**: `300s`

> Each sub-check scores `0` if its underlying script exits non-zero, so a crashed script
> can never be reported as healthy.

### Sub-checks

#### Check Cleanup Policy Configuration Score for Repository in `${GCP_PROJECT_ID}`

Scores whether configured cleanup policies pass governance checks.

- **Robot task name**: <code>Check Cleanup Policy Configuration Score for Repository in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `cleanup_policy`
- **Underlying script**: `check-cleanup-policies.sh`
- **Tags**: `gcp`, `artifact registry`, `cleanup policy`, `access:read-only`, `data:logs-config`
- **Reads**: `ARTIFACT_REGISTRY_LOCATION`, `ARTIFACT_REGISTRY_REPOSITORY`
- **Pass condition**: `len(cleanup_policy_issues.json) == 0` and script exit code `0`


#### Check Stale Image Score for Repository in `${GCP_PROJECT_ID}`

Scores whether stale tagged images are within configured thresholds.

- **Robot task name**: <code>Check Stale Image Score for Repository in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `stale_images`
- **Underlying script**: `identify-stale-images.sh`
- **Tags**: `gcp`, `artifact registry`, `stale images`, `access:read-only`, `data:logs-config`
- **Reads**: `STALE_IMAGE_THRESHOLD_DAYS`
- **Pass condition**: `len(stale_images_issues.json) == 0` and script exit code `0`


#### Check Untagged Image Score for Repository in `${GCP_PROJECT_ID}`

Scores whether untagged manifests are within configured thresholds.

- **Robot task name**: <code>Check Untagged Image Score for Repository in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `untagged_images`
- **Underlying script**: `identify-untagged-images.sh`
- **Tags**: `gcp`, `artifact registry`, `untagged images`, `access:read-only`, `data:logs-config`
- **Reads**: `UNTAGGED_IMAGE_THRESHOLD_DAYS`
- **Pass condition**: `len(untagged_images_issues.json) == 0` and script exit code `0`


#### Check Storage Utilization Score for Repository in `${GCP_PROJECT_ID}`

Scores whether repository storage utilization is within budget.

- **Robot task name**: <code>Check Storage Utilization Score for Repository in `${GCP_PROJECT_ID}`</code>
- **Sub-metric name**: `storage_utilization`
- **Underlying script**: `report-repository-storage-utilization.sh`
- **Tags**: `gcp`, `artifact registry`, `storage`, `access:read-only`, `data:logs-config`
- **Reads**: `STORAGE_UTILIZATION_THRESHOLD_GB`
- **Pass condition**: `len(storage_utilization_issues.json) == 0` and script exit code `0`


## Inputs

| Name | Type | Description | Default | Required |
|---|---|---|---|---|
| `GCP_PROJECT_ID` | string | GCP project ID containing Artifact Registry repositories. | — | yes |
| `ARTIFACT_REGISTRY_LOCATIONS` | string | Comma-separated Artifact Registry locations, or `All`. | `All` | no |
| `ARTIFACT_REGISTRY_REPOSITORIES` | string | Comma-separated repository IDs to scope checks; `All` discovers all. | `All` | no |
| `ARTIFACT_REGISTRY_LOCATION` | string | Single Artifact Registry location when scoped to one repository SLX. | `` | no |
| `ARTIFACT_REGISTRY_REPOSITORY` | string | Single Artifact Registry repository name when scoped to one repository SLX. | `` | no |
| `STALE_IMAGE_THRESHOLD_DAYS` | string | Days without pull or update after which an image is considered stale. | `90` | no |
| `UNTAGGED_IMAGE_THRESHOLD_DAYS` | string | Age threshold in days for untagged manifests flagged for cleanup. | `30` | no |
| `STORAGE_UTILIZATION_THRESHOLD_GB` | string | Repository estimated storage GB that triggers a utilization issue; `0` disables. | `50` | no |
| `MIN_TAGS_TO_KEEP` | string | Recommended minimum tagged versions to retain per package. | `5` | no |

## Secrets

| Name | Description | Required |
|---|---|---|
| `gcp_credentials` | GCP service account JSON with Artifact Registry read access (`roles/artifactregistry.reader`). | yes |

## Outputs

- Monitor health score (`0.0`–`1.0`) pushed by `sli.robot`, plus sub-metrics
  `cleanup_policy`, `stale_images`, `untagged_images`, `storage_utilization`
- `discovered_repositories.json`
- `cleanup_policy_issues.json`
- `stale_images_issues.json`
- `untagged_images_issues.json`
- `legacy_gcr_issues.json`
- `storage_utilization_report.json`, `storage_utilization_issues.json`
- `cleanup_policy_recommendations.json`

## How to invoke

### Production (RunWhen runner / worker)

The platform **runner** schedules work on a location **worker**. The worker
image (`rw-base-runtime`) executes Robot via `runrobot.sh` with
`RW_PATH_TO_ROBOT` set to the bound path under `/home/runwhen/collection/`.

- **Runbook**: `codebundles/gcp-artifact-registry-governance/runbook.robot`
- **Monitor**: `codebundles/gcp-artifact-registry-governance/sli.robot`

### Local development (devcontainer only)

`ro` is a dev-time wrapper in `codecollection-devtools` — not the enterprise runtime.

```bash
cd codebundles/gcp-artifact-registry-governance
export GCP_PROJECT_ID=...
export ARTIFACT_REGISTRY_LOCATION=...
export ARTIFACT_REGISTRY_REPOSITORY=...
ro runbook.robot
```

### Standalone scripts (no Robot)

Set the input variables above, then run the matching script:

```bash
cd codebundles/gcp-artifact-registry-governance
export GCP_PROJECT_ID=...
export GOOGLE_APPLICATION_CREDENTIALS=/path/to/gcp_sa.json
export ARTIFACT_REGISTRY_LOCATIONS=All
export ARTIFACT_REGISTRY_REPOSITORIES=All
bash discover-artifact-repositories.sh
bash check-cleanup-policies.sh
bash identify-stale-images.sh
bash identify-untagged-images.sh
bash detect-legacy-gcr-usage.sh
bash report-repository-storage-utilization.sh
bash generate-cleanup-policy-recommendations.sh
```

## Source files

- `runbook.robot` — orchestrates tools and raises issues
- `sli.robot` — monitor scoring (`sli.robot` runtime file)
- `gcp-artifact-registry-helpers.sh` — shared helpers: auth, discovery, filters, issue emission.
- `discover-artifact-repositories.sh` — Bash helper script `discover-artifact-repositories.sh`.
- `check-cleanup-policies.sh` — Bash helper script `check-cleanup-policies.sh`.
- `identify-stale-images.sh` — Bash helper script `identify-stale-images.sh`.
- `identify-untagged-images.sh` — Bash helper script `identify-untagged-images.sh`.
- `detect-legacy-gcr-usage.sh` — Bash helper script `detect-legacy-gcr-usage.sh`.
- `report-repository-storage-utilization.sh` — Bash helper script `report-repository-storage-utilization.sh`.
- `generate-cleanup-policy-recommendations.sh` — Bash helper script `generate-cleanup-policy-recommendations.sh`.
