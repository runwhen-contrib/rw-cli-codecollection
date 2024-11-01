## Infrastructure
This will build out a simple AKS Cluster in a dedicated resource group, and enables the configure SP to own those resources, which will be needed when testing discovery of this with RunWhen Local (through the Taskfile in the parent directory)

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


## Notes / Bugs 

If you see this error, just re-run the plan. There is a timing / dependency issue here which will work the second time. 
```
│ Error: creating Kubernetes Cluster 
│ Resource Group Name: "azure-aks"
│ Kubernetes Cluster Name: "aks-cl-1"): performing CreateOrUpdate: unexpected status 400 (400 Bad Request) with response: {
│   "code": "CustomKubeletIdentityMissingPermissionError",
│   "details": null,
│   "message": "The cluster using user-assigned managed identity must be granted 'Managed Identity Operator' role to assign kubelet identity. You can run 'az role assignment create --assignee \u003ccontrol-plane-identity-principal-id\u003e --role 'Managed Identity Operator' --scope \u003ckubelet-identity-resource-id\u003e' to grant the permission. See https://learn.microsoft.com/en-us/azure/aks/use-managed-identity#add-role-assignment",
│   "subcode": ""
│  }
│ 
│   with azurerm_kubernetes_cluster.aks_cluster,
│   on main.tf line 39, in resource "azurerm_kubernetes_cluster" "aks_cluster":
│   39: resource "azurerm_kubernetes_cluster" "aks_cluster" {
│ 
╵
```