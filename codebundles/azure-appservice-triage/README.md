# Azure App Service Triage
Checks key App Service metrics and the service plan, fetches logs, config and activities for the service and generates a report of present issues for any found.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_USERNAME`: Service principal's client ID
- `AZ_SECRET_VALUE`: The credential secret value from the app registration
- `AZ_TENANT`: The Azure tenancy ID
- `AZ_SUBSCRIPTION`: The Azure subscription ID
- `AZ_RESOURCE_GROUP`: The Azure resource group that these resources reside in
- `VMSCALEDSET`: The name of the VM Scaled Set in the resource group to target with checks

## Notes

This codebundle assumes the service principal authentication flow.

## TODO
- [ ] look for notable activities in list
- [ ] config best practices check
- [ ] Add documentation