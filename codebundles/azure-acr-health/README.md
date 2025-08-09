# Azure Container Registry (ACR) Health Bundle

This bundle provides comprehensive health checks for Azure Container Registries (ACR), including reachability, usage SKU metrics, pull/push success ratio, and storage utilization. It uses Robot Framework tasks and Bash scripts to collect, parse, and score ACR health.

## Included Health Checks

- **Registry Reachability**: Verifies that the ACR endpoint is reachable and responsive.
- **Usage SKU Metric**: Checks the current SKU and usage limits for the registry.
- **Pull/Push Success Ratio**: Analyzes the success rate of image pull and push operations.
- **Storage Utilization**: Checks the storage usage against quota/thresholds.

## Main Tasks

- `Check ACR Reachability`
- `Check ACR Usage SKU Metric`
- `Check ACR Pull/Push Success Ratio`
- `Check ACR Storage Utilization`
- `Score ACR Health Metrics`
- `Generate Comprehensive ACR Health Score`

## How It Works

1. **Bash scripts** (e.g., `acr_reachability.sh`, `acr_usage_sku.sh`, etc.) collect raw data from Azure Container Registry.
2. **Robot Framework tasks** run these scripts, parse the output, and (for SLI) calculate a health score.
3. **Next steps scripts** (e.g., `next_steps_reachability.sh`) analyze the parsed output and generate JSON issues or recommendations.
4. **SLI tasks** aggregate the results and push a health score metric.

## Usage

- Configure your environment variables (registry name, resource group, subscription, thresholds, etc.).
- Run the desired Robot Framework task (e.g., from `runbook.robot` or `sli.robot`).
- Review the output and health scores.

### Example

To check a specific registry:

```
export ACR_NAME="myregistry"
robot runbook.robot
```

## Directory Structure

- `runbook.robot` - Main runbook for health checks and issue creation.
- `sli.robot` - SLI/score-only version for health scoring.
- `acr_reachability.sh`, `acr_usage_sku.sh`, `acr_pull_push_ratio.sh`, `acr_storage_utilization.sh` - Data collection scripts.
- `next_steps_reachability.sh`, `next_steps_usage_sku.sh`, `next_steps_pull_push_ratio.sh`, `next_steps_storage_utilization.sh` - Next steps/issue analysis scripts.
- `.test/` - Example and test cases. 