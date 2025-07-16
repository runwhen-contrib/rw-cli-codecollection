# Azure VM Disk Health Bundle

This bundle provides comprehensive health checks for Azure Virtual Machines, including disk utilization, memory usage, uptime, and patch status. It uses Robot Framework tasks and Bash scripts to collect, parse, and score VM health.

## Included Health Checks

- **Disk Utilization**: Checks if any disk is above the configured threshold.
- **Memory Utilization**: Checks if memory usage is above the configured threshold.
- **Uptime**: Checks if system uptime exceeds the configured threshold.
- **Patch Status**: Checks if there are pending OS patches.

## Main Tasks

- `Check Disk Utilization for VMs in Resource Group`
- `Check Memory Utilization for VMs in Resource Group`
- `Check Uptime for VMs in Resource Group`
- `Check Last Patch Status for VMs in Resource Group`
- `Score Disk Utilization for VMs in Resource Group`
- `Score Memory Utilization for VMs in Resource Group`
- `Score Uptime for VMs in Resource Group`
- `Score Last Patch Status for VMs in Resource Group`
- `Generate Comprehensive VM Health Score`

## How It Works

1. **Bash scripts** (e.g., `vm_disk_utilization.sh`, `vm_memory_check.sh`, etc.) collect raw data from Azure VMs.
2. **Robot Framework tasks** run these scripts, parse the output, and (for SLI) calculate a health score.
3. **Next steps scripts** (e.g., `next_steps_disk_utilization.sh`) analyze the parsed output and generate JSON issues or recommendations.
4. **SLI tasks** aggregate the results and push a health score metric.

## Usage

- Configure your environment variables (resource group, subscription, thresholds, etc.).
- Run the desired Robot Framework task (e.g., from `runbook.robot` or `sli.robot`).
- Review the output and health scores.

## Directory Structure

- `runbook.robot` - Main runbook for health checks and issue creation.
- `sli.robot` - SLI/score-only version for health scoring.
- `vm_disk_utilization.sh`, `vm_memory_check.sh`, `vm_uptime_check.sh`, `vm_last_patch_check.sh` - Data collection scripts.
- `next_steps_disk_utilization.sh`, `next_steps_memory_check.sh`, `next_steps_uptime.sh`, `next_steps_patch_time.sh` - Next steps/issue analysis scripts.
- `.test/` - Example and test cases (see below for Terraform usage).


### How to Use the Terraform Code

1. Prepare your secrets file (tf.secret)
Create a file named tf.secret in your Terraform directory with the following structure:

tf.secret (example)
```
ARM_SUBSCRIPTION_ID="your-azure-subscription-id"
AZURE_SUBSCRIPTION_ID=$ARM_SUBSCRIPTION_ID
AZURE_RESOURCE_GROUP="your-azure-resource-group"
VM_NAME="your-vm-name"
AZ_TENANT_ID="your-tenant-id"
AZ_CLIENT_SECRET="your-client-secret"
AZ_CLIENT_ID="your-client-id"
TF_VAR_service_principal_id=$(az ad sp show --id $AZ_CLIENT_ID --query id -o tsv)
TF_VAR_subscription_id=$ARM_SUBSCRIPTION_ID
TF_VAR_tenant_id=$AZ_TENANT_ID
TF_VAR_client_id=$AZ_CLIENT_ID
TF_VAR_client_secret=$AZ_CLIENT_SECRET
```

2. Build Infra
```
task build-infra
```