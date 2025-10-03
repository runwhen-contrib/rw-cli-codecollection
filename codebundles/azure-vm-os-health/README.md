# Azure VM OS Health Bundle

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

## Key Features

### OS Filtering
- **Linux-only**: Scripts automatically filter out Windows VMs and only process Linux machines
- **OS Detection**: Uses Azure VM metadata to determine OS type before attempting commands

### Robust Error Handling
- **Graceful Failures**: Individual VM connection failures don't stop the entire script
- **Issue Creation**: Failed connections create structured issues for tracking
- **Detailed Logging**: Clear error messages for troubleshooting

### Configurable Timeouts
- **VM Status Timeout**: `VM_STATUS_TIMEOUT` (default: 10s) - Time to check VM power state
- **Command Timeout**: `COMMAND_TIMEOUT` (default: 45-60s) - Time for run-command execution
- **Overall Timeout**: `TIMEOUT_SECONDS` (default: 30s) - General script timeout

## Usage

- Configure your environment variables (resource group, subscription, thresholds, etc.).
- Optionally set `VM_INCLUDE_LIST` and/or `VM_OMIT_LIST` to control which VMs are checked:
    - `VM_INCLUDE_LIST`: Comma-separated shell-style wildcards (e.g., `web-*,db-*`). Only VMs matching any pattern are included.
    - `VM_OMIT_LIST`: Comma-separated shell-style wildcards. Any VM matching a pattern is excluded.
    - If both are empty, all Linux VMs in the resource group are checked.
- Run the desired Robot Framework task (e.g., from `runbook.robot` or `sli.robot`).
- Review the output and health scores.

### Environment Variables

```bash
# Required
AZURE_SUBSCRIPTION_ID="your-subscription-id"
AZ_RESOURCE_GROUP="your-resource-group"

# Optional - VM filtering
VM_INCLUDE_LIST="web-*,db-*"  # Only check VMs matching patterns
VM_OMIT_LIST="*-test"         # Skip VMs matching patterns

# Optional - Performance tuning
MAX_PARALLEL_JOBS=5           # Number of concurrent VM checks
VM_STATUS_TIMEOUT=10          # Seconds to check VM power state
COMMAND_TIMEOUT=45            # Seconds for run-command execution
TIMEOUT_SECONDS=30            # General script timeout
```

### Example

To check only VMs starting with `web-` or `db-`, but omit any ending with `-test`:

```bash
export VM_INCLUDE_LIST="web-*,db-*"
export VM_OMIT_LIST="*-test"
export COMMAND_TIMEOUT=60  # Longer timeout for patch checks
robot runbook.robot
```

## Directory Structure

- `runbook.robot` - Main runbook for health checks and issue creation.
- `sli.robot` - SLI/score-only version for health scoring.
- `vm_disk_utilization.sh`, `vm_memory_check.sh`, `vm_uptime_check.sh`, `vm_last_patch_check.sh` - Data collection scripts.
- `next_steps_disk_utilization.sh`, `next_steps_memory_check.sh`, `next_steps_uptime.sh`, `next_steps_patch_time.sh` - Next steps/issue analysis scripts.
- `.test/` - Example and test cases (see below for Terraform usage).

## Error Handling

The scripts handle various failure scenarios gracefully:

- **Connection Failures**: When a VM can't be reached, an issue is created and the script continues
- **Authentication Issues**: Clear error messages for Azure CLI authentication problems
- **VM Power State**: Non-running VMs are skipped with appropriate status codes
- **Command Timeouts**: Long-running commands are terminated with configurable timeouts
- **Invalid Responses**: Malformed Azure responses are handled with error reporting

### Issue Types

- `ConnectionError`: Failed to connect to VM or get status
- `VMNotRunning`: VM is not in running state
- `CommandTimeout`: Run-command execution timed out
- `InvalidResponse`: Unexpected response format from Azure

## How to Use the Terraform Code

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