## Infrastructure
This will build out a simple VM scale set in a dedicated resource group, and enables the configure SP to own those resources, which will be needed when testing discovery of this with RunWhen Local (through the Taskfile in the parent directory)

## Usage

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
export TF_VAR_subscription_id=$ARM_SUBSCRIPTION_ID
export TF_VAR_tenant_id=$AZ_TENANT_ID
```