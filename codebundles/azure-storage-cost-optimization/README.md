# Azure Storage Cost Optimization

This codebundle analyzes Azure storage resources to identify cost optimization opportunities.

## Purpose

- Identify unattached/orphaned managed disks
- Find old snapshots consuming storage costs
- Detect storage accounts without lifecycle management policies
- Identify over-provisioned geo-redundant storage
- Find underutilized Premium disks that can be downgraded

## Tasks

### Analyze Azure Storage Cost Optimization Opportunities
Examines storage resources across the subscription and identifies:
- **Unattached Disks**: Managed disks not attached to any VM
- **Old Snapshots**: Snapshots older than threshold (default 90 days)
- **Missing Lifecycle Policies**: Storage accounts without data lifecycle management
- **Over-provisioned Redundancy**: GRS/GZRS that could use LRS/ZRS
- **Underutilized Premium**: Premium disks with low IOPS that could be Standard SSD

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `AZURE_SUBSCRIPTION_IDS` | Comma-separated subscription IDs to analyze | Current subscription |
| `AZURE_RESOURCE_GROUPS` | Comma-separated resource groups (empty = all) | "" |
| `AZURE_SUBSCRIPTION_NAME` | Subscription name for display purposes | "" |
| `COST_ANALYSIS_LOOKBACK_DAYS` | Days to analyze for utilization data | 30 |
| `SNAPSHOT_AGE_THRESHOLD_DAYS` | Age threshold for old snapshots | 90 |
| `LOW_COST_THRESHOLD` | Savings threshold for LOW classification | 500 |
| `MEDIUM_COST_THRESHOLD` | Savings threshold for MEDIUM classification | 2000 |
| `HIGH_COST_THRESHOLD` | Savings threshold for HIGH classification | 10000 |
| `AZURE_DISCOUNT_PERCENTAGE` | Discount percentage off MSRP | 0 |
| `TIMEOUT_SECONDS` | Task timeout in seconds | 1800 |

## Storage Cost Analysis Details

### Unattached Disks
- Lists all managed disks with state "Unattached"
- Calculates monthly cost based on disk SKU and size
- Recommends review and deletion of unused disks

### Old Snapshots
- Identifies snapshots older than configured threshold
- Calculates storage costs at ~$0.05/GB/month
- Recommends cleanup and automated retention policies

### Lifecycle Management
- Checks each storage account for lifecycle policies
- Identifies Hot tier accounts without auto-tiering
- Estimates 60-95% savings from proper tiering

### Redundancy Optimization
- Identifies GRS/GZRS/RA-GRS storage accounts
- Calculates potential savings from downgrading to LRS/ZRS
- Provides guidance on when geo-redundancy is needed

### Premium Disk Utilization
- Queries IOPS metrics for Premium disks
- Identifies disks using <20% of provisioned IOPS
- Recommends Standard SSD for cost savings

## Requirements

- Azure credentials with Reader role on subscriptions
- Azure Monitor access for disk metrics

## Related Codebundles

This codebundle is part of a suite of Azure cost optimization tools:

| Codebundle | Purpose |
|------------|---------|
| `azure-subscription-cost-report` | Historical cost reports, trend analysis, cost increase alerts |
| `azure-vm-cost-optimization` | VM rightsizing and deallocation |
| `azure-aks-cost-optimization` | AKS node pool utilization and autoscaling |
| `azure-appservice-cost-optimization` | App Service Plan rightsizing |
| `azure-databricks-cost-optimization` | Databricks cluster auto-termination |
