# gcp-cloudrun-utilization-health — Test Infrastructure

Tests discovery and template rendering for the `gcp-cloudrun-utilization-health`
codebundle.

## What the fixtures create

`terraform/` provisions four Cloud Run services in the target project, covering
both healthy and mis-scaled configurations that the scaling/config checks can
detect:

| Service | maxScale | minScale | Concurrency | Purpose |
|---|---|---|---|---|
| `healthy-service-test001` | 5 | 0 | 80 | Properly bounded/sane scaling (should raise no scaling issue) |
| `unbounded-service-test001` | unset | 0 | 80 | Unbounded max instances (cost risk) |
| `mininstances-service-test001` | 2 | 1 | 80 | Min instances keep an idle instance warm |
| `lowconcurrency-service-test001` | 5 | 0 | 5 | Very low concurrency target |

The utilization **metric** checks (CPU/memory over-utilization, under-utilization)
depend on Cloud Monitoring time-series data, which is produced by real traffic to
the services. To exercise those paths, send traffic to the fixtures (e.g.
`hey`/`wrk` load generation) over the `METRIC_LOOKBACK_PERIOD` before running the
runbook, or point `RESOURCES` at a live service with known utilization.

## Usage

```bash
cd .test

# 1. Credentials: create terraform/tf.secret with:
#    export GOOGLE_APPLICATION_CREDENTIALS="/path/to/svc.json"
#    export TF_VAR_project_id="my-gcp-project"
#    and place the key at .test/gcp.json.secret for RunWhen Local

# 2. Provision fixtures
task build-infra

# 3. Generate config + run discovery + validate rules
task generate-rwl-config GCP_PROJECT_ID=my-gcp-project RW_WORKSPACE=my-workspace
task run-rwl-discovery
task validate-generation-rules

# 4. Review rendered templates
ls output/workspaces/

# 5. Tear everything down
task clean
```

`task` (default) runs the full flow: check-unpushed-commits → build-infra →
generate-rwl-config → run-rwl-discovery → validate-generation-rules.

## Requirements

- `terraform`, `gcloud`, `docker`, `jq`, `yq`, `ajv`, `curl`
- GCP service account with `roles/run.admin`,
  `roles/iam.serviceAccountUser`, and `roles/monitoring.viewer` on the test
  project
- Cloud Run Admin API and Cloud Monitoring API enabled on the project
