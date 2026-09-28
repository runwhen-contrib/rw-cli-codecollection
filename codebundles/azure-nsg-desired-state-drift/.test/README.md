# Test infrastructure — Azure NSG desired-state drift

Terraform provisions a resource group and a sample NSG with one inbound rule for manual validation of this CodeBundle in a real Azure subscription.

## Prerequisites

- Azure CLI and Terraform installed
- `terraform/tf.secret` (not committed) with `ARM_SUBSCRIPTION_ID`, `AZ_TENANT_ID`, `AZ_CLIENT_ID`, `AZ_CLIENT_SECRET` per `docs/skills/test-infra-azure.md`

## Usage

```bash
task build-terraform-infra
```

After apply, capture a baseline with:

```bash
az network nsg show -g <rg> -n <nsg> -o json > /tmp/nsg.json
```

Build a `json-bundle` file with a top-level `nsgs` array containing that object (or run the CodeBundle export task and save `nsg_live_bundle.json`). Point `BASELINE_PATH` at that file for drift testing.

```bash
task cleanup-terraform-infra
```

See `Taskfile.yaml` for `validate-generation-rules` and other tasks copied from the standard Azure CodeBundle test layout.
