# gcp-cloud-function-health — Test Infrastructure

Tests discovery and template rendering for the `gcp-cloud-function-health`
codebundle.

## What the fixtures create

`terraform/` provisions four Cloud Functions in the target project,
covering both generations and both health states:

| Function | Generation | State | Purpose |
|---|---|---|---|
| `healthy-function-test001` | gen1 | ACTIVE | Properly deployed HTTP function |
| `healthy-function-gen2-test001` | gen2 | ACTIVE | Properly deployed HTTP function (Cloud Run backed) |
| `failing-function-test001` | gen1 | FAILED | Broken build (deliberate syntax error) |
| `failing-function-gen2-test001` | gen2 | FAILED | Broken build (deliberate syntax error) |

The failing functions deploy via `gcloud functions deploy ... || true`
in `null_resource`s because terraform's function resources would fail
the whole apply on a broken build. The failed deployments leave the
functions in GCP in FAILED states for the health checks to detect.

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
- GCP service account with `roles/cloudfunctions.admin`,
  `roles/cloudfunctions.developer`, `roles/storage.admin`,
  `roles/run.admin`, `roles/iam.serviceAccountUser` on the test project
