# Test Harness — gcp-artifact-registry-spend-analysis

## Overview

This CodeBundle analyzes Artifact Registry and legacy Container Registry spend
from a **GCP BigQuery billing export**. Billing export is configured at the
billing-account (organization) level, and its historical rows cannot be
synthesized by terraform — so unlike most bundles, this harness does not
*provision* the data it tests against. It is **pointed at a real, existing
billing export table** instead.

`terraform/` is therefore a documented no-op that preserves the standard
layout; `task build-infra` runs it and then verifies the configured table is
readable.

This harness uses the shared task library at `codebundles/.test-tasks/Taskfile.yaml`
(`shared:upload-slxs`, `shared:delete-slxs`, `shared:check-rwp-config`).

## Setup

1. Put GCP credentials with **BigQuery Data Viewer** and **BigQuery Job User**
   on the billing-export project at `.test/gcp.json.secret` (this is the
   directory mounted as `/shared` for discovery, and `workspaceInfo.yaml`
   references `/shared/gcp.json.secret`).

2. Create `terraform/tf.secret`:

   ```bash
   export GOOGLE_APPLICATION_CREDENTIALS="$PWD/../gcp.json.secret"
   export GCP_BILLING_EXPORT_TABLE="<billing-project>.<dataset>.gcp_billing_export_v1_XXXXXX"
   export GCP_PROJECT_IDS="<project-to-analyze>"

   # Project the BigQuery job runs in and is billed to. Defaults to the export
   # table's project. Set this when the export project grants only dataset read
   # access (no bigquery.jobs.create) -- the job then runs in a project you can
   # use and reads the export cross-project.
   # export GCP_BILLING_QUERY_PROJECT="<project-to-run-the-query-in>"

   # optional tuning — these also flow into workspaceInfo.yaml `custom:`
   # export COST_ANALYSIS_LOOKBACK_DAYS="30"
   # export ARTIFACT_COST_SPIKE_MULTIPLIER="2"
   # export ARTIFACT_MOM_GROWTH_THRESHOLD_PERCENT="25"
   # export ARTIFACT_PROJECT_COST_THRESHOLD_PERCENT="20"
   # export GCP_ORG_WIDE_REPORT="false"
   ```

   If `GCP_BILLING_EXPORT_TABLE` is left unset, the bundle falls back to
   auto-discovering any `gcp_billing_export_v1_*` table in the configured
   projects; `task build-infra` fails fast with setup instructions rather than
   letting the robots silently score 0.

3. For SLX upload, export the RunWhen Platform config:

   ```bash
   export RW_WORKSPACE=<workspace>
   export RW_API_URL=<papi host>
   export RW_WORKSPACE_RUNNER=<runner>
   export RW_PAT=<token>
   ```

## Tasks

| Task | What it does |
|---|---|
| `task` (default) | structure validation → unpushed check → build-infra → generate-rwl-config → discovery → generation-rule validation |
| `task validate-structure` | `validate-all-tests.sh` — required files, executable bits, mock aggregation |
| `task build-infra` | no-op terraform + **verify the billing export table is readable** |
| `task generate-rwl-config` | writes `workspaceInfo.yaml`, including the `custom:` block that feeds `gcp_billing_export_table` into the SLI/runbook templates |
| `task run-rwl-discovery` | runs RunWhen Local discovery → `output/workspaces/` |
| `task validate-generation-rules` | schema-validates `.runwhen/generation-rules/*.yaml` |
| `task upload-slxs` | `shared:upload-slxs` — V4 typed sync push of SLX + SLI + runbook |
| `task delete-slxs` | `shared:delete-slxs` |
| `task clean` | terraform destroy + delete-slxs + discovery cleanup + local artifact cleanup |

## Cleanup

```bash
task clean
```
