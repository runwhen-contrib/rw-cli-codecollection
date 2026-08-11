# gcp-cloudrun-service-health — Test Infrastructure

Tests discovery and template rendering for the `gcp-cloudrun-service-health`
codebundle.

## What the fixtures create

`terraform/` provisions Cloud Run services in the target project, covering both
healthy and unhealthy states. Because a failed/greypre Cloud Run deployment is
hard to provision declaratively (a broken container stops the service from
becoming Ready), the fixtures use `google_cloud_run_service` for a healthy
service and `null_resource` + `gcloud run deploy` for services that fail to
become Ready (broken container) or roll back.

| Service | State | Purpose |
|---|---|---|
| `cr-healthy-<suffix>` | Ready, latest revision serving 100% | Healthy baseline |
| `cr-broken-<suffix>` | Never Ready (container startup failure) | Failed revision / cannot serve traffic |
| `cr-latest0-<suffix>` | Ready but 0% traffic on latest | Serving check / rollout rollback |

The fixture services are tagged with `env=test`, `lifecycle=deleteme`, and
`product=runwhen` for identification and cleanup.

## Usage

```bash
cd .test

# 1. Credentials: create terraform/tf.secret with:
#    export GOOGLE_APPLICATION_CREDENTIALS="/path/to/svc.json"
#    export TF_VAR_project_id="my-gcp-project"
#    export TF_VAR_region="us-central1"
#    export TF_VAR_resource_suffix="test001"

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
- GCP service account with `roles/run.admin`, `roles/iam.serviceAccountUser`,
  and `roles/storage.objectViewer` (to build from source) on the test project
