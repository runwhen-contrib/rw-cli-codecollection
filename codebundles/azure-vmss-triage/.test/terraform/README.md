# Usage

### State management
State is managed locally with `terraform.tfstate` and is gitignored. 

### Auth
az login --use-device-code

### Requirements
The following vars must exist:

```
export ARM_SUBSCRIPTION_ID=[]
export AZ_TENANT_ID=[]
export AZ_CLIENT_SECRET=[]
export AZ_CLIENT_ID=[]
export AZ_SECRET_ID=[]
export TF_VAR_sp_principal_id=$(az ad sp show --id $AZ_CLIENT_ID --query id -o tsv)
```

## az cli 
export TF_VAR_subscription_id="your-subscription-id"
export TF_VAR_tenant_id="your-tenant-id"
