# Azure AKS Cluster Triage
This CodeBundle checks for AKS Cluster Health based on how Azure is reporting resource health, network configuration recommendations, activities that have occured, and provisioning status of resources. 

## Configuration

The SLI & TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:
- `AZ_RESOURCE_GROUP`: The Azure resource group that these resources reside in
- `AKS_CLUSTER`: The name of the AKS Cluster in the resource group to target with checks
- `TIME_PERIOD_MINUTES`: The time window, in minutes, to look back for activities and events which may indicate issues. 

## Notes

This codebundle assumes the service principal authentication flow which is handled from the import secret Keyword.


## TODO
- [ ] Add documentation