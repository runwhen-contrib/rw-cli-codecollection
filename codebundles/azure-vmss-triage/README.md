# Azure Virtual Machine Scale Set Triage
This codebundle runs a suite of metrics checks for a VM Scale Set in Azure. It fetches activities and the current configuration which is added to a report for review at that point in time.

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_USERNAME`: Service principal's client ID
- `AZ_SECRET_VALUE`: The credential secret value from the app registration
- `AZ_TENANT`: The Azure tenancy ID
- `AZ_SUBSCRIPTION`: The Azure subscription ID
- `AZ_RESOURCE_GROUP`: The Azure resource group that these resources reside in
- `VMSCALESET`: The name of the VM Scale Set in the resource group to target with checks

## Notes

This codebundle assumes the service principal authentication flow

## TODO
- [ ] remote exec functionality
- [ ] look for notable activities in list
- [ ] config best practices check
- [ ] Add documentation