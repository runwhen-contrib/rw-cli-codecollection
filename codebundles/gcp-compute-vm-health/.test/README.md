# gcp-compute-vm-health — Test Infrastructure

Tests discovery and template rendering for the `gcp-compute-vm-health`
codebundle.

## What the fixtures create

`terraform/` provisions a VPC/subnet plus three VMs in the target project,
covering both health states and an exclusion scenario:

| VM | State | Purpose |
|---|---|---|
| `healthy-vm-<suffix>` | RUNNING | Properly configured standalone VM that should pass all checks (healthy scenario) |
| `stopped-vm-<suffix>` | STOPPED | Standalone VM in a non-RUNNING state — the uptime/summary checks should flag it (@severity 3) |
| `grouped-vm-<suffix>` | RUNNING | Member of an unmanaged instance group — MUST be excluded from standalone discovery (no SLX generated) |

`discovery_expected_standalone_vms` output confirms the bundle should discover
only `healthy-vm` and `stopped-vm` (the grouped VM is excluded).

> Note: fully reproducing the `overdue_reboot` and `missing_patches_and_full_disk`
> scenarios requires additional state (older `lastStartTimestamp`, OS Config /
> vulnerability data, and Ops Agent disk metrics) that is not something the
> Terraform resource can create directly; the fixture above validates
> discovery, health-state flagging (non-RUNNING), and instance-group exclusion.

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
- GCP service account with `roles/compute.admin`, `roles/compute.instanceAdmin.v1`,
  and (for the stopped-VM fixture) compute instance start/stop permissions on
  the test project.
