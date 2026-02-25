# Azure AKS Cost Optimization

This codebundle analyzes Azure Kubernetes Service (AKS) cluster node pools to identify cost optimization opportunities.

## Purpose

- Analyze AKS node pool utilization metrics
- Identify underutilized node pools with autoscaling
- Recommend minimum node count reductions
- Suggest alternative VM sizes for better cost/performance ratio
- Provide capacity-planned recommendations with safety margins

## Tasks

### Analyze AKS Node Pool Resizing Opportunities Based on Utilization Metrics
Examines all AKS clusters and node pools in the subscription and identifies:
- **Underutilized autoscaling pools**: Node pools with peak CPU/memory below thresholds
- **Static overprovisioned pools**: Fixed-size pools with low utilization
- **VM type optimization**: Pools that could benefit from different VM sizes

## Capacity Planning Methodology

The analysis uses a two-tier approach:
1. **Minimum nodes** based on AVERAGE utilization (handles typical workload)
2. **Maximum nodes** based on PEAK utilization (handles traffic spikes)

Safety margins (configurable):
- `MIN_NODE_SAFETY_MARGIN_PERCENT`: Buffer for minimum nodes (default: 150%)
- `MAX_NODE_SAFETY_MARGIN_PERCENT`: Buffer for maximum nodes (default: 150%)

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

## Operational Safety Limits

The script includes safety limits to prevent aggressive recommendations:
- `MAX_REDUCTION_PERCENT`: Maximum reduction per change (default: 50%)
- `MIN_USER_POOL_NODES`: Minimum nodes for user pools (default: 5)
- `MIN_SYSTEM_POOL_NODES`: Minimum nodes for system pools (default: 3)

## Requirements

- Azure credentials with Reader role on subscriptions
- Azure Monitor access for metrics
- AKS cluster access

## Related Codebundles

This codebundle is part of a suite of Azure cost optimization tools:

| Codebundle | Purpose |
|------------|---------|
| `azure-subscription-cost-report` | Historical cost reports, trend analysis, cost increase alerts |
| `azure-vm-cost-optimization` | VM rightsizing and deallocation |
| `azure-storage-cost-optimization` | Orphaned disks, old snapshots, lifecycle policies |
| `azure-appservice-cost-optimization` | App Service Plan rightsizing |
| `azure-databricks-cost-optimization` | Databricks cluster auto-termination |
