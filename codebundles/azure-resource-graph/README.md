# Azure Resource Graph
This codebundle analyzes Azure Resource Graph data. It fetches and evaluates active resource graph queries for a specified Azure subscription.

## Configuration

The TaskSet requires initialization to import necessary secrets and user variables. The following variables should be set:

- `AZURE_RESOURCE_SUBSCRIPTION_ID`: The Azure Subscription ID for the resource.
- `azure_credentials`: A secret containing `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_CLIENT_SECRET` for service principal authentication.

## Notes

This codebundle assumes the service principal authentication flow.