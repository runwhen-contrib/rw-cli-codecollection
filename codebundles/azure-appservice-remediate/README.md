# Azure App Service Remediation
Provides a set of tasks to manage the scale and replicas of a Azure App Service.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `azure_credentials`: azure credentials file contents
- `AZ_RESOURCE_GROUP`: The Azure resource group that these resources reside in
- `APPSERVICE`: The name of the App Service workload in the resource group to target with tasks

## Notes

This codebundle assumes the service principal authentication flow.

## TODO
- [ ] Add documentation