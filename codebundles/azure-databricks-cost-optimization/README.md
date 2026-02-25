# Azure Databricks Cost Optimization

This codebundle analyzes Azure Databricks workspaces and clusters to identify cost optimization opportunities.

## Purpose

- Identify clusters without auto-termination configured
- Find idle running clusters wasting compute costs
- Detect over-provisioned clusters with low utilization
- Calculate both VM and DBU (Databricks Unit) costs

## Tasks

### Analyze Databricks Cluster Auto-Termination and Over-Provisioning Opportunities
Examines all Databricks workspaces and clusters in the subscription and identifies:
- **Missing Auto-Termination**: Clusters that will run indefinitely
- **Idle Clusters**: Running clusters with no active jobs
- **Over-Provisioned Clusters**: Clusters with low CPU/memory utilization

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

## Cost Calculation

Databricks costs include:
- **VM Costs**: Azure compute charges for worker and driver nodes
- **DBU Costs**: Databricks Unit charges based on cluster tier and size

The analysis estimates both components to provide accurate savings projections.

## Auto-Termination Best Practices

Recommended auto-termination settings:
- **Interactive clusters**: 30-60 minutes of inactivity
- **Job clusters**: Terminate immediately after job completion (default behavior)
- **Dev/test clusters**: 15-30 minutes of inactivity

## Requirements

- Azure credentials with Reader role on subscriptions
- Access to Databricks workspace APIs
- Azure Monitor access for metrics

## Related Codebundles

This codebundle is part of a suite of Azure cost optimization tools:

| Codebundle | Purpose |
|------------|---------|
| `azure-subscription-cost-report` | Historical cost reports, trend analysis, cost increase alerts |
| `azure-vm-cost-optimization` | VM rightsizing and deallocation |
| `azure-aks-cost-optimization` | AKS node pool utilization and autoscaling |
| `azure-storage-cost-optimization` | Orphaned disks, old snapshots, lifecycle policies |
| `azure-appservice-cost-optimization` | App Service Plan rightsizing |
