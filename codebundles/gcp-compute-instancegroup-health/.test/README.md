# gcp-compute-instancegroup-health — Test Infrastructure

Tests discovery and template rendering for the `gcp-compute-instancegroup-health`
codebundle.

## What the fixtures create

`terraform/` provisions two instance groups in the target project, covering the
main health scenarios:

| Group | Type | State | Purpose |
|---|---|---|---|
| `ig-healthy-test001` | Managed (+ autoscaler) | Healthy | Properly sized managed group with autoscaling, 2 members, health check |
| `ig-degraded-test001` | Unmanaged (empty) | Degraded | Unmanaged group with no members to exercise the member-health and summary checks |

The healthy group is backed by an instance template and an autoscaler; the
degraded group is an unmanaged instance group intentionally left empty so the
bundle flags it.

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
- GCP service account with `roles/compute.instanceAdmin.v1`,
  `roles/compute.networkAdmin`, `roles/iam.serviceAccountUser`,
  `roles/osconfig.viewer`, and `roles/monitoring.viewer` on the test project

## Test scenarios

| Scenario | Fixture | Expected issues |
|---|---|---|
| `healthy_group` | `ig-healthy-test001` | 0 |
| `degraded_members` | `ig-degraded-test001` | 1 (member health, severity 3) |
