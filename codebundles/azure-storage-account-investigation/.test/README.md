# Test Infrastructure

Terraform provisions a storage account with public blob access enabled, diagnostic settings forwarding StorageBlobLogs to Log Analytics, and sample RBAC role assignments for integration testing.

## Prerequisites

- Azure CLI authenticated with permissions to create storage accounts and Log Analytics workspaces
- Copy `terraform/tf.secret.example` to `terraform/tf.secret` with service principal credentials (see azure-acr-health bundle)

## Usage

```bash
task build-infra    # terraform apply
task clean          # terraform destroy
```

Outputs include `storage_account_name`, `resource_group_name`, and `log_analytics_workspace_id` for runbook configuration.
