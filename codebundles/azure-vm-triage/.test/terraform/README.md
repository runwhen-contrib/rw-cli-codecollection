# Usage

### State management
State is managed locally with `terraform.tfstate` and is gitignored. 

### Requirements
The following vars must exist:
- export ARM_SUBSCRIPTION_ID=[sub_id]

# Auth
az login --use-device-code

## az cli 
export TF_VAR_subscription_id="your-subscription-id"
export TF_VAR_tenant_id="your-tenant-id"
