# Azure Data Factory Health
This codebundle runs a suite of metrics checks for Data Factory in Azure. It identifies:
- Check Azure Data Factory Availability

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZURE_SUBSCRIPTION_ID`: The Azure subscription ID
- `AZURE_RESOURCE_GROUP`: The Azure Resource Group

## Testing 
See the .test directory for infrastructure test code. 

## Notes

This codebundle assumes the service principal authentication flow