### Testing `azure-cosmosdb-utilization-health`

This directory holds optional validation and Terraform for a sample Cosmos DB account.

1. **Quick validation**: From `.test`, run `task` (or `bash validate-all-tests.sh`) to `bash -n` all bundle scripts.
2. **Terraform**: Configure Azure credentials per your environment, then `task build-infra` to create a minimal Cosmos DB account in a resource group for live metric queries. Destroy with `task clean`.

Do not commit secrets. Use `terraform.tfvars` locally for non-production subscriptions only.
