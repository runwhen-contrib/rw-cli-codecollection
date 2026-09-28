# Test infrastructure — Azure Subnet Egress Validation

This directory contains a Terraform stack and Taskfile tasks used to exercise the CodeBundle against a real Azure subscription.

## Prerequisites

- Azure CLI and Terraform installed
- `terraform/tf.secret` (not committed) with `ARM_SUBSCRIPTION_ID`, `AZ_TENANT_ID`, `AZ_CLIENT_ID`, `AZ_CLIENT_SECRET` exported for Terraform and `az`

## Usage

1. Copy `terraform/terraform.tfvars` values to match your subscription (resource group name, region, VNet name).
2. `cd terraform && terraform init && terraform apply`
3. From `.test`, run `task generate-rwl-config` (after sourcing `tf.secret`) to build `workspaceInfo.yaml` for RunWhen Local.

Tag test resources with `lifecycle: deleteme` for easy identification.
