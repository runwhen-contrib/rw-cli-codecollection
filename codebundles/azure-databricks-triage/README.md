# Azure Databricks Workspace Health
This codebundle checks the activity stream of a azure databrick and surfaces issues.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_USERNAME`: Service principal's client ID
- `AZ_SECRET_VALUE`: The credential secret value from the app registration
- `AZ_TENANT`: The Azure tenancy ID
- `AZ_SUBSCRIPTION`: The Azure subscription ID
- `AZ_RESOURCE_GROUP`: The Azure resource group that these resources reside in
- `ADB`: The azure databricks name.

## Notes

This codebundle assumes the service principal authentication flow

## TODO
- [ ] Add documentation