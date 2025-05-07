# Azure Key Vault  Health
This codebundle runs a suite of metrics checks for Key Vault in Azure. It identifies:
- Check Key Vault Availability
- Check Key Vault Configuration
- Check Expiring Key Vault Items (Keys, Secrets and Certificates)
- Check Key Vault Logs for Issues
- Check Key Vault Performance Metrics

## Configuration

The TaskSet requires initialization to import necessary secrets, services, and user variables. The following variables should be set:

- `AZ_USERNAME`: Service principal's client ID
- `AZ_SECRET_VALUE`: The credential secret value from the app registration
- `AZ_TENANT`: The Azure tenancy ID
- `AZ_SUBSCRIPTION`: The Azure subscription ID

## Testing 
See the .test directory for infrastructure test code. 

## Notes

This codebundle assumes the service principal authentication flow