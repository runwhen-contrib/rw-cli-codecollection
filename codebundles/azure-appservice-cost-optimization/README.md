# Azure App Service Cost Optimization

This codebundle analyzes Azure App Service Plans to identify cost optimization opportunities.

## Purpose

- Identify empty App Service Plans with no deployed apps
- Find underutilized plans with low CPU/memory usage
- Recommend rightsizing (SKU downgrades or capacity reductions)
- Provide risk-assessed optimization options
- Support multiple optimization strategies

## Tasks

### Analyze App Service Plan Cost Optimization
Examines all App Service Plans in the subscription and identifies:
- **Empty Plans**: Plans with no apps deployed (100% waste)
- **Underutilized Plans**: Plans with low CPU/memory utilization
- **Rightsizing Opportunities**: Plans that can use smaller SKUs or fewer instances

## Optimization Strategies

| Strategy | Target Utilization | Risk Tolerance | Best For |
|----------|-------------------|----------------|----------|
| `aggressive` | 85-90% max CPU | Medium-High | Dev/test, non-critical |
| `balanced` | 75-80% max CPU | Low-Medium | Standard production |
| `conservative` | 60-70% max CPU | Low only | Critical production |

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `AZURE_SUBSCRIPTION_IDS` | Comma-separated subscription IDs to analyze | Current subscription |
| `AZURE_RESOURCE_GROUPS` | Comma-separated resource groups (empty = all) | "" |
| `AZURE_SUBSCRIPTION_NAME` | Subscription name for display purposes | "" |
| `LOW_COST_THRESHOLD` | Savings threshold for LOW classification | 500 |
| `MEDIUM_COST_THRESHOLD` | Savings threshold for MEDIUM classification | 2000 |
| `HIGH_COST_THRESHOLD` | Savings threshold for HIGH classification | 10000 |
| `OPTIMIZATION_STRATEGY` | Strategy: aggressive/balanced/conservative | balanced |
| `TIMEOUT_SECONDS` | Task timeout in seconds | 1800 |

## Analysis Details

### Utilization Analysis
- Queries 7 days of Azure Monitor metrics
- Analyzes both average and peak CPU/memory
- Projects utilization after proposed changes

### Options Table
For each plan, the analysis generates multiple optimization options:
- Keep current configuration
- Scale down by 1 instance
- Scale down by 50%
- SKU downgrade (e.g., P3v3 → P2v3)
- Combined SKU + capacity reduction

Each option includes:
- Projected utilization (CPU and memory)
- Risk assessment (LOW/MEDIUM/HIGH)
- Confidence score
- Monthly cost and savings

## Requirements

- Azure credentials with Reader role on subscriptions
- Azure Monitor access for metrics

## Related Codebundles

This codebundle is part of a suite of Azure cost optimization tools:

| Codebundle | Purpose |
|------------|---------|
| `azure-subscription-cost-report` | Historical cost reports, trend analysis, cost increase alerts |
| `azure-vm-cost-optimization` | VM rightsizing and deallocation |
| `azure-aks-cost-optimization` | AKS node pool utilization and autoscaling |
| `azure-storage-cost-optimization` | Orphaned disks, old snapshots, lifecycle policies |
| `azure-databricks-cost-optimization` | Databricks cluster auto-termination |
