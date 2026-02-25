# Azure Storage Cost Optimization

This codebundle analyzes Azure storage resources to identify cost optimization opportunities.

## Purpose

- Identify unattached/orphaned managed disks
- Find old snapshots consuming storage costs
- Detect storage accounts without lifecycle management policies
- Identify over-provisioned geo-redundant storage
- Find underutilized Premium disks that can be downgraded

## Performance Modes

The script supports multiple performance modes for handling large environments:

| Mode | Description | Speed | Accuracy | Use Case |
|------|-------------|-------|----------|----------|
| `full` | Resource Graph + actual Azure Monitor metrics (default) | 🏃 Medium | Precise | Accurate savings analysis |
| `quick` | Resource Graph + estimated usage (no metrics) | ⚡ Fast | Approximate | Large environments, quick scans |
| `sample` | Resource Graph + metrics for N resources, extrapolate | 🏃 Medium | Statistical | Very large environments (1000+ accounts) |

### Performance Features

- **Azure Resource Graph**: ALWAYS used (when available) for 10-100x faster resource discovery
- **Parallel Metrics Collection**: Configurable concurrent API calls in full/sample modes (default: 10)
- **Estimate Mode**: Skip metrics collection entirely using account-type heuristics (quick mode)
- **Sampling with Extrapolation**: Analyze a subset and project to full population (sample mode)

## Tasks

### Analyze Azure Storage Cost Optimization Opportunities
Examines storage resources across the subscription and identifies:
- **Unattached Disks**: Managed disks not attached to any VM
- **Old Snapshots**: Snapshots older than threshold (default 90 days)
- **Missing Lifecycle Policies**: Storage accounts without data lifecycle management
- **Over-provisioned Redundancy**: GRS/GZRS that could use LRS/ZRS
- **Underutilized Premium**: Premium disks with low IOPS that could be Standard SSD

## Configuration

### Core Settings

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
| `TIMEOUT_SECONDS` | Task timeout in seconds | 1500 |

### Performance Settings

| Variable | Description | Default |
|----------|-------------|---------|
| `SCAN_MODE` | Performance mode: `full`, `quick`, or `sample` | full |
| `MAX_PARALLEL_JOBS` | Maximum concurrent metrics collection jobs | 10 |
| `SAMPLE_SIZE` | Number of resources to sample in sample mode | 20 |

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

### Redundancy Optimization (Enhanced)
- Identifies GRS/GZRS/RA-GRS storage accounts
- **Collects actual storage usage (GB/TB)** via Azure Monitor metrics
- **Applies regional pricing** for accurate cost estimation
- **Calculates actual monthly/annual savings** per account
- Generates detailed savings breakdown table with:
  - Per-account used capacity
  - Current monthly cost (GRS/RA-GRS)
  - Projected LRS monthly cost
  - Individual and total savings
- Provides guidance on when geo-redundancy is needed vs. can be downgraded

### Premium Disk Utilization
- Queries IOPS metrics for Premium disks
- Identifies disks using <20% of provisioned IOPS
- Recommends Standard SSD for cost savings

## Performance Comparison

All modes use Azure Resource Graph for fast resource discovery. The difference is in metrics collection:

| Scenario | quick mode | full mode | sample mode |
|----------|------------|-----------|-------------|
| 50 storage accounts | ~10 sec | ~1 min | ~30 sec |
| 200 storage accounts | ~15 sec | ~3 min | ~45 sec |
| 500 storage accounts | ~20 sec | ~6 min | ~1 min |

## Sample Output

The redundancy optimization task now produces a detailed savings report:

```
SUMMARY:
  • Geo-Redundant Accounts: 43
  • Accounts with Usage Data: 38
  • Total Used Capacity: 1,250.50 GB (1.22 TB)

COST ANALYSIS:
  • Current Monthly Cost (GRS/RA-GRS): $485.20
  • Projected Monthly Cost (LRS): $242.60
  • POTENTIAL MONTHLY SAVINGS: $242.60
  • POTENTIAL ANNUAL SAVINGS: $2,911.20

SAVINGS BREAKDOWN BY ACCOUNT:
┌─────────────────────────────────┬────────────┬──────────────┬──────────────┬───────────────┬─────────────┬──────────────┐
│ Storage Account                 │ Region     │ Used (GB)    │ Redundancy   │ Current Cost  │ LRS Cost    │ Savings      │
├─────────────────────────────────┼────────────┼──────────────┼──────────────┼───────────────┼─────────────┼──────────────┤
│ mystorageaccount01              │ eastus2    │       450.25 │ GRS          │       $16.58  │      $8.29  │       $8.29  │
│ backupstorage02                 │ eastus     │       125.00 │ RA-GRS       │        $4.83  │      $2.30  │       $2.53  │
...
```

## Requirements

- Azure credentials with Reader role on subscriptions
- Azure Monitor access for storage and disk metrics
- `UsedCapacity` metric must be available on storage accounts (enabled by default for most accounts)

## Related Codebundles

This codebundle is part of a suite of Azure cost optimization tools:

| Codebundle | Purpose |
|------------|---------|
| `azure-subscription-cost-report` | Historical cost reports, trend analysis, cost increase alerts |
| `azure-vm-cost-optimization` | VM rightsizing and deallocation |
| `azure-aks-cost-optimization` | AKS node pool utilization and autoscaling |
| `azure-appservice-cost-optimization` | App Service Plan rightsizing |
| `azure-databricks-cost-optimization` | Databricks cluster auto-termination |
