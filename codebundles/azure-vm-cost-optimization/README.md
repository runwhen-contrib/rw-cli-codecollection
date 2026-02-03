# Azure VM Cost Optimization

This codebundle analyzes Azure Virtual Machines to identify cost optimization opportunities.

## Purpose

- Identify VMs that are stopped but not deallocated (still incurring costs)
- Find oversized VMs with low CPU/memory utilization
- Recommend rightsizing to B-series burstable instances
- Calculate potential cost savings

## Tasks

### Analyze Virtual Machine Rightsizing and Deallocation Opportunities
Examines all VMs in the subscription and identifies:
- **Stopped-not-deallocated VMs**: VMs in "Stopped" state still reserving compute resources
- **Oversized VMs**: VMs with consistently low CPU/memory utilization that can be downsized

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `AZURE_SUBSCRIPTION_IDS` | Comma-separated subscription IDs to analyze | Current subscription |
| `AZURE_RESOURCE_GROUPS` | Comma-separated resource groups (empty = all) | "" |
| `AZURE_SUBSCRIPTION_NAME` | Subscription name for display purposes | "" |
| `COST_ANALYSIS_LOOKBACK_DAYS` | Days to analyze for utilization data | 30 |
| `LOW_COST_THRESHOLD` | Savings threshold for LOW classification | 500 |
| `MEDIUM_COST_THRESHOLD` | Savings threshold for MEDIUM classification | 2000 |
| `HIGH_COST_THRESHOLD` | Savings threshold for HIGH classification | 10000 |
| `AZURE_DISCOUNT_PERCENTAGE` | Discount percentage off MSRP | 0 |
| `TIMEOUT_SECONDS` | Task timeout in seconds | 1800 |

## Analysis Details

### Stopped-not-Deallocated Detection
- Checks VM power state via Azure API
- Identifies VMs that show "Stopped" but not "Deallocated"
- These VMs continue to incur full compute charges

### Rightsizing Analysis
- Queries Azure Monitor for CPU and memory metrics
- Identifies VMs with peak utilization below thresholds
- Recommends B-series burstable instances for low-utilization workloads
- Filters out Databricks and AKS-managed VMs (handled separately)

## Requirements

- Azure credentials with Reader role on subscriptions
- Azure Monitor access for metrics

## Related Codebundles

This codebundle is part of a suite of Azure cost optimization tools:

| Codebundle | Purpose |
|------------|---------|
| `azure-subscription-cost-report` | Historical cost reports, trend analysis, cost increase alerts |
| `azure-aks-cost-optimization` | AKS node pool utilization and autoscaling |
| `azure-storage-cost-optimization` | Orphaned disks, old snapshots, lifecycle policies |
| `azure-appservice-cost-optimization` | App Service Plan rightsizing |
| `azure-databricks-cost-optimization` | Databricks cluster auto-termination |
